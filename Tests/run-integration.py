#!/usr/bin/env python3
"""使用临时本地 SSH 服务验证真实转发，不读取或修改用户 SSH 配置。"""

import getpass
import os
from pathlib import Path
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        """持续回传数据，让 Swift 验证端口变更前后的同一条 TCP 连接。"""
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data)


class EchoServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def compile_test(project, build):
    """只编译 Foundation 核心与一份集成检查，不启动应用界面。"""
    sources = [
        project / "TunnelBar" / name
        for name in (
            "Models.swift", "ConfigStore.swift", "SSHTransport.swift", "TunnelManager.swift"
        )
    ] + [project / "Tests" / "integration.swift"]
    missing = [str(path.relative_to(project)) for path in sources if not path.is_file()]
    if missing:
        raise RuntimeError("缺少集成检查源文件：" + "、".join(missing))
    executable = build / "integration"
    subprocess.run(
        ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
         str(build / "ModuleCache"), "-o", str(executable), *map(str, sources)],
        cwd=project, check=True, timeout=120,
    )
    return executable


def make_fixture(root, port):
    """生成仅在本次验证有效的主机密钥、客户端密钥和 SSH 配置。"""
    for name in ("host_key", "client_key"):
        subprocess.run(
            ["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)],
            check=True, timeout=10,
        )
    host_key = (root / "host_key.pub").read_text().split()
    known_hosts = root / "known_hosts"
    known_hosts.write_text(f"[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n")
    server_config = root / "sshd_config"
    server_config.write_text("\n".join([
        f"Port {port}", "ListenAddress 127.0.0.1", f"HostKey {root / 'host_key'}",
        f"PidFile {root / 'sshd.pid'}", f"AuthorizedKeysFile {root / 'client_key.pub'}",
        f"AllowUsers {getpass.getuser()}", "PasswordAuthentication no",
        "KbdInteractiveAuthentication no", "UsePAM no", "AllowTcpForwarding yes",
        "PermitTTY no", "LogLevel ERROR",
    ]) + "\n")
    client_config = root / "ssh_config"
    client_config.write_text("\n".join([
        "Host fixture", "    HostName 127.0.0.1", f"    Port {port}",
        f"    User {getpass.getuser()}", f"    IdentityFile {root / 'client_key'}",
        f"    UserKnownHostsFile {known_hosts}", "    GlobalKnownHostsFile /dev/null",
        "    IdentityAgent none", "    IdentitiesOnly yes", "    StrictHostKeyChecking yes",
    ]) + "\n")
    return server_config, client_config


def wait_for_server(server, port):
    """有界等待当前测试启动的 sshd 监听回环端口。"""
    for _ in range(50):
        if server.poll() is not None:
            raise RuntimeError("本地测试 sshd 提前退出。")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("本地测试 sshd 没有在 5 秒内开始监听。")


def stop_process_group(server):
    """按父子关系结束本次测试的进程树，涵盖另建进程组的 sshd 子连接。"""
    if server.poll() is not None:
        return
    process_table = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
    children = {}
    for line in process_table.splitlines():
        pid, parent = map(int, line.split())
        children.setdefault(parent, []).append(pid)
    owned = [server.pid]
    for parent in owned:
        owned.extend(children.get(parent, []))
    # 先终止子连接再停监听进程，避免父进程退出后丢失实际归属关系。
    for pid in reversed(owned):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        server.wait(timeout=3)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()


def run():
    """建立本地测试环境，执行一组真实转发检查，并在异常时同样清理。"""
    project = Path(__file__).resolve().parents[1]
    build = project / "build"
    build.mkdir(exist_ok=True)
    executable = compile_test(project, build)
    with tempfile.TemporaryDirectory(prefix="ssh-fixture-", dir=build) as temporary:
        root = Path(temporary)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        server_config, client_config = make_fixture(root, port)
        with EchoServer(("127.0.0.1", 0), EchoHandler) as echo:
            echo_thread = threading.Thread(target=echo.serve_forever, daemon=True)
            echo_thread.start()
            with (root / "sshd.log").open("w+") as log:
                server = subprocess.Popen(
                    ["/usr/sbin/sshd", "-D", "-e", "-f", str(server_config)],
                    stdout=subprocess.DEVNULL, stderr=log, start_new_session=True,
                )
                integration = None
                try:
                    wait_for_server(server, port)
                    command = [str(executable), str(client_config), str(echo.server_address[1])]
                    integration = subprocess.Popen(
                        command, cwd=project, start_new_session=True,
                    )
                    deadline = time.monotonic() + 90
                    restart_request = root / "restart.request"
                    while integration.poll() is None:
                        if time.monotonic() >= deadline:
                            raise subprocess.TimeoutExpired(command, 90)
                        if restart_request.exists():
                            restart_request.unlink()
                            stop_process_group(server)
                            server = None
                            server = subprocess.Popen(
                                ["/usr/sbin/sshd", "-D", "-e", "-f", str(server_config)],
                                stdout=subprocess.DEVNULL, stderr=log, start_new_session=True,
                            )
                        time.sleep(0.1)
                    if integration.returncode:
                        raise subprocess.CalledProcessError(integration.returncode, command)
                except (RuntimeError, subprocess.SubprocessError):
                    log.flush()
                    log.seek(0)
                    diagnostic = log.read()[-4000:]
                    if "sandbox initialization failed" in diagnostic or "sandbox_init" in diagnostic:
                        print("Apple sshd 的认证子进程无法在当前沙箱中初始化；此本地检查需要在沙箱外执行。")
                    print(diagnostic)
                    raise
                finally:
                    if integration is not None:
                        stop_process_group(integration)
                    if server is not None:
                        stop_process_group(server)
                    echo.shutdown()
                    echo_thread.join(timeout=2)


if __name__ == "__main__":
    run()
