#!/usr/bin/env python3
"""构建独立更新宿主和测试密钥，验证发布门禁；--serve 提供可切换的本地失败/重定向源。"""

import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]
PRODUCTS = REPO / "macos/build/Build/Products/Debug"
SPARKLE_BIN = REPO / "macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin"


def run(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    keys = root / "keys"
    keys.mkdir(mode=0o700)
    generator = root / "keys.swift"
    generator.write_text('''import CryptoKit
import Foundation
for name in ["valid", "wrong"] {
    let key = Curve25519.Signing.PrivateKey()
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let secret = root.appendingPathComponent(name + ".key")
    try key.rawRepresentation.base64EncodedString().write(to: secret, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
    try key.publicKey.rawRepresentation.base64EncodedString().write(
        to: root.appendingPathComponent(name + ".pub"), atomically: true, encoding: .utf8)
}
''')
    run(["swift", generator, keys])
    framework = PRODUCTS / "Sparkle.framework"
    old = root / "old/QuietChat Update Test.app"
    (old / "Contents/MacOS").mkdir(parents=True)
    (old / "Contents/Frameworks").mkdir()
    run(["ditto", framework, old / "Contents/Frameworks/Sparkle.framework"])
    run([
        "swiftc", "-swift-version", "6", "-parse-as-library", "-module-name", "QuietChatUpdateTest",
        "-F", PRODUCTS, "-framework", "Sparkle", "-I", PRODUCTS,
        REPO / "macos/QuietChat/App/AppUpdateController.swift", REPO / "macos/QuietChat/App/Log.swift",
        REPO / "tools/release/fixtures/UpdateTestApp.swift", PRODUCTS / "QuietChatCore.o",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-o", old / "Contents/MacOS/UpdateTestApp",
    ])
    properties = plistlib.loads((REPO / "macos/Configs/QuietChat-Info.plist").read_bytes())
    properties.update({
        "CFBundleIdentifier": "io.github.OumCc.QuietChat.UpdateIntegration",
        "CFBundleExecutable": "UpdateTestApp", "CFBundleName": "QuietChat Update Test",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "30001",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "SUFeedURL": "http://127.0.0.1:8765/appcast.xml", "SUPublicEDKey": (keys / "valid.pub").read_text(),
        "FixtureStatePath": str(root / "state.json"),
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    })
    (old / "Contents/Info.plist").write_bytes(plistlib.dumps(properties))
    new = root / "new/QuietChat Update Test.app"
    run(["ditto", old, new])
    properties.update(CFBundleShortVersionString="1.1.1", CFBundleVersion="30002")
    (new / "Contents/Info.plist").write_bytes(plistlib.dumps(properties))
    for app in [old, new]:
        run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
             REPO / "macos/Configs/QuietChat.entitlements", app])
        run(["codesign", "--verify", "--deep", "--strict", app])

    for case, app, version, key in [
        ("valid", new, "1.1.1", "valid"), ("wrong-key", new, "1.1.1", "wrong"),
        ("no-update", old, "1.1.0", "valid"),
    ]:
        archives = root / case
        archives.mkdir()
        contents = root / (case + "-contents")
        contents.mkdir()
        run(["ditto", app, contents / app.name])
        (contents / "Applications").symlink_to("/Applications")
        run(["hdiutil", "create", "-quiet", "-volname", "QuietChat Update Test", "-srcfolder", contents,
             "-format", "UDZO", archives / ("QuietChat-" + version + ".dmg")])
        (archives / ("QuietChat-" + version + ".md")).write_text("# 更新验证\n\n本次升级验证真实替换与重启。\n")
        env = dict(os.environ, SPARKLE_ED25519_PRIVATE_KEY=(keys / (key + ".key")).read_text())
        result = subprocess.run([
            "bash", str(REPO / "tools/release/prepare-update.sh"), str(app), str(archives),
            str(SPARKLE_BIN), "http://127.0.0.1:8765/",
        ], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == (case != "wrong-key"), result.stdout + result.stderr
        print(case + ": 发布门禁符合预期")

    for case in ["corrupt", "tampered-feed", "redirect", "slow"]:
        shutil.copytree(root / "valid", root / case)
    archive = root / "corrupt/QuietChat-1.1.1.dmg"
    payload = bytearray(archive.read_bytes())
    payload[-1] ^= 1
    archive.write_bytes(payload)
    result = subprocess.run(["swift", str(REPO / "tools/release/verify-update.swift"), str(new), str(archive),
                             str(root / "corrupt/appcast.xml")], capture_output=True, text=True)
    assert result.returncode != 0
    print("corrupt: 篡改归档被公钥验证拒绝")
    feed = root / "tampered-feed/appcast.xml"
    feed.write_bytes(feed.read_bytes().replace(b"1.1.1", b"9.9.9"))
    result = subprocess.run([str(SPARKLE_BIN / "sign_update"), "--verify", "--ed-key-file",
                             str(keys / "valid.key"), str(feed)], capture_output=True, text=True)
    assert result.returncode != 0
    print("tampered-feed: 篡改清单被签名验证拒绝")
    (root / "active-case").write_text("valid")
    print("测试产物：" + str(root))


class Source(http.server.BaseHTTPRequestHandler):
    def __init__(self, *args, root, **kwargs):
        self.root = root
        super().__init__(*args, **kwargs)

    def do_GET(self):
        case = (self.root / "active-case").read_text().strip()
        with (self.root / "requests.jsonl").open("a") as log:
            log.write(json.dumps({"case": case, "path": self.path, "time": time.time()}) + "\n")
        path = self.path.split("?", 1)[0].split("/")[-1]
        if case == "redirect" and path == "QuietChat-1.1.1.dmg":
            self.send_response(302)
            self.send_header("Location", "/payload.dmg")
            self.end_headers()
            return
        if path == "payload.dmg":
            path = "QuietChat-1.1.1.dmg"
        file = self.root / case / path
        if not file.is_file():
            self.send_error(404)
            return
        data = file.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Type", "application/xml" if path.endswith("xml") else "application/octet-stream")
        self.end_headers()
        try:
            for offset in range(0, len(data), 32768):
                self.wfile.write(data[offset:offset + 32768])
                if case == "slow" and path.endswith("dmg"):
                    time.sleep(0.12)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--reset-host", action="store_true", help="关闭测试宿主并创建新的旧构建安装副本")
    parser.add_argument("--reset-consent", action="store_true", help="仅清除隔离 bundle ID 的检查选择")
    parser.add_argument("--probe", action="store_true", help="用 Sparkle 公共回调执行下载失败与取消验证")
    parser.add_argument("--check-offline", action="store_true", help="验证真实更新控制器在拒绝且检查已到期时不联网")
    args = parser.parse_args()
    if args.check_offline:
        subprocess.run(["pkill", "-x", "UpdateTestApp"], capture_output=True)
        app = args.root / ("offline-" + str(time.time_ns())) / "QuietChat Update Test.app"
        run(["ditto", args.root / "new/QuietChat Update Test.app", app])
        run(["defaults", "write", "io.github.OumCc.QuietChat.UpdateIntegration", "SUEnableAutomaticChecks", "-bool", "false"])
        subprocess.run(["defaults", "delete", "io.github.OumCc.QuietChat.UpdateIntegration", "SULastCheckTime"], capture_output=True)
        (args.root / "active-case").write_text("valid")
        requests = args.root / "requests.jsonl"
        before = requests.read_text() if requests.exists() else ""
        started = time.time()
        process = subprocess.Popen([str(app / "Contents/MacOS/UpdateTestApp")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(3)
            state_path = args.root / "state.json"
            state = json.loads(state_path.read_text())
            assert state_path.stat().st_mtime >= started and not state["automaticChecks"]
            assert (requests.read_text() if requests.exists() else "") == before
            print("offline: 检查已到期但拒绝自动检查，真实控制器启动无网络请求")
        finally:
            process.terminate()
            process.communicate(timeout=10)
    elif args.probe:
        subprocess.run(["pkill", "-x", "UpdateTestApp"], capture_output=True)
        base = args.root / ("probe-" + str(time.time_ns()))
        base.mkdir()
        binary = base / "DownloadProbe"
        run(["clang", "-fobjc-arc", "-F", PRODUCTS, "-framework", "Sparkle", "-framework", "AppKit",
             REPO / "tools/release/fixtures/DownloadProbe.m", "-Wl,-rpath,@executable_path/../Frameworks",
             "-o", binary])
        for case in ["wrong-key", "tampered-feed", "no-update", "corrupt", "slow", "redirect"]:
            app = base / case / "QuietChat Update Test.app"
            run(["ditto", args.root / "new/QuietChat Update Test.app", app])
            info = app / "Contents/Info.plist"
            properties = plistlib.loads(info.read_bytes())
            properties.update(CFBundleShortVersionString="1.1.0", CFBundleVersion="30001", CFBundleExecutable="DownloadProbe")
            info.write_bytes(plistlib.dumps(properties))
            shutil.copy2(binary, app / "Contents/MacOS/DownloadProbe")
            run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
                 REPO / "macos/Configs/QuietChat.entitlements", app])
            (args.root / "active-case").write_text(case)
            output = run([app / "Contents/MacOS/DownloadProbe", case], timeout=40)
            assert plistlib.loads(info.read_bytes())["CFBundleVersion"] == "30001"
            print(output.strip(), flush=True)
    elif args.reset_host:
        subprocess.run(["pkill", "-x", "UpdateTestApp"], capture_output=True)
        app = args.root / ("installed-" + str(time.time_ns())) / "QuietChat Update Test.app"
        run(["ditto", args.root / "new/QuietChat Update Test.app", app])
        info = app / "Contents/Info.plist"
        properties = plistlib.loads(info.read_bytes())
        properties.update(CFBundleShortVersionString="1.1.0", CFBundleVersion="30001")
        info.write_bytes(plistlib.dumps(properties))
        run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
             REPO / "macos/Configs/QuietChat.entitlements", app])
        if args.reset_consent:
            subprocess.run(["defaults", "delete", "io.github.OumCc.QuietChat.UpdateIntegration",
                            "SUEnableAutomaticChecks"], capture_output=True)
        print(app)
    elif args.serve:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 8765), functools.partial(Source, root=args.root))
        print("本地更新源已启动：127.0.0.1:8765", flush=True)
        server.serve_forever()
    else:
        prepare(args.root)


if __name__ == "__main__":
    main()
