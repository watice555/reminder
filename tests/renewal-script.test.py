"""Offline renewal flow tests; fake Xcode/iPhone services, real zsh/plist/date tools."""
import datetime
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.wuth.cyclereminder"
TEAM = "YBWKLTC4VN"
DEVICE = "test-iphone"

FAKE_TOOL = r'''
import os, pathlib, shutil, sys
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["RENEWAL_TEST_ROOT"])
with (root / "calls").open("a") as f:
    f.write(tool + " " + " ".join(args) + "\n")
if tool == "security":
    sys.stdout.buffer.write(pathlib.Path(args[args.index("-i") + 1]).read_bytes())
elif tool == "xcodebuild":
    if "-showdestinations" in args:
        failure = os.environ.get("RENEWAL_TEST_FAILURE")
        if failure == "device-plugin":
            print("DVTCoreDeviceCore: Symbol not found: CoreDevice", file=sys.stderr)
            print("{ platform:iOS, id:placeholder, name:Any iOS Device }")
            sys.exit(0)
        if failure == "device-query":
            print("Xcode device query failed", file=sys.stderr)
            sys.exit(1)
        if failure == "no-device":
            print("{ platform:iOS, id:placeholder, name:Any iOS Device }")
            sys.exit(0)
        print("{ platform:iOS, id:test-iphone, name:Test iPhone }")
    else:
        assert not list((root / "Library/Developer/Xcode/UserData/Provisioning Profiles").glob("ours.mobileprovision"))
        if os.environ.get("RENEWAL_TEST_FAILURE") == "build":
            sys.exit(1)
        if os.environ.get("RENEWAL_TEST_FAILURE") == "download-then-fail":
            shutil.copy(root / "new.mobileprovision", root / "Library/Developer/Xcode/UserData/Provisioning Profiles/ours.mobileprovision")
            sys.exit(1)
        app = root / "build/Build/Products/Debug-iphoneos/CycleReminder.app"
        app.mkdir(parents=True, exist_ok=True)
        shutil.copy(root / "new.mobileprovision", app / "embedded.mobileprovision")
        shutil.copy(root / "new-info.plist", app / "Info.plist")
elif tool == "xcrun":
    if "install" in args and os.environ.get("RENEWAL_TEST_FAILURE") == "install":
        sys.exit(1)
    if "launch" in args and os.environ.get("RENEWAL_TEST_FAILURE") == "launch":
        print("invalid code signature")
        sys.exit(1)
elif tool == "codesign" and os.environ.get("RENEWAL_TEST_FAILURE") == "signature":
    sys.exit(1)
'''


class RenewalFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="renewal-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
        self.old_expiry = self.now + datetime.timedelta(days=1)
        self.new_expiry = self.now + datetime.timedelta(days=7)
        self.profile_dir = self.root / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        self.profile_dir.mkdir(parents=True)
        self.ours = self.profile_dir / "ours.mobileprovision"
        self.write_profile(self.ours, self.old_expiry)
        self.unrelated = self.profile_dir / "other.mobileprovision"
        self.write_profile(self.unrelated, self.old_expiry, bundle="com.example.other")
        self.other_bytes = self.unrelated.read_bytes()
        self.write_profile(self.profile_dir / "wildcard.mobileprovision", self.old_expiry, bundle="*")
        self.write_profile(self.root / "new.mobileprovision", self.new_expiry)
        self.write_plist(self.root / "new-info.plist", {"CFBundleIdentifier": BUNDLE})
        (self.root / "ios/CycleReminder.xcodeproj").mkdir(parents=True)
        (self.root / "scripts").mkdir()
        helper = (ROOT / "scripts/renewal-profile.zsh").read_text()
        script = (ROOT / "续期.command").read_text()
        for name in ["security", "curl", "xcrun", "codesign", "sleep"]:
            fake = self.root / name
            fake.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
            fake.chmod(0o700)
            for prefix in ["/usr/bin/", "/bin/"]:
                script = script.replace(prefix + name, str(fake))
                helper = helper.replace(prefix + name, str(fake))
        xcode = self.root / "Xcode.app"
        xcodebuild = xcode / "Contents/Developer/usr/bin/xcodebuild"
        xcodebuild.parent.mkdir(parents=True)
        xcodebuild.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
        xcodebuild.chmod(0o700)
        script = script.replace('/Applications/Xcode.app', str(xcode))
        script = script.replace('/tmp/CycleReminderRenewal', str(self.root / "build"))
        script = script.replace('$HOME/Library', str(self.root / "Library"))
        (self.root / "scripts/renewal-profile.zsh").write_text(helper)
        self.script = self.root / "续期.command"
        self.script.write_text(script)

    def write_plist(self, path, data):
        path.write_bytes(plistlib.dumps(data))

    def write_profile(self, path, expiry, bundle=BUNDLE, team=TEAM, device=DEVICE):
        self.write_plist(path, {
            "TeamIdentifier": [team],
            "Entitlements": {"application-identifier": f"{team}.{bundle}"},
            "ProvisionedDevices": [device],
            "ExpirationDate": expiry,
        })

    def run_flow(self, failure=""):
        env = dict(os.environ, RENEWAL_TEST_ROOT=str(self.root), RENEWAL_TEST_FAILURE=failure)
        result = subprocess.run(["/bin/zsh", str(self.script)], env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.output = result.stdout + result.stderr
        self.calls = (self.root / "calls").read_text()
        self.assertEqual(self.unrelated.read_bytes(), self.other_bytes)
        self.assertTrue((self.profile_dir / "wildcard.mobileprovision").exists())
        self.assertFalse((self.root / "Library/Application Support/CycleReminder/Renewal/active.lock").exists())
        return result.returncode

    def assert_rejected(self, message):
        self.assertNotEqual(self.run_flow(), 0, self.output)
        self.assertIn(message, self.output)
        self.assertNotIn("device install", self.calls)
        self.assertTrue(self.ours.exists(), self.output)
        self.assertNotIn("✅", self.output)

    def test_fresh_profile_installs_and_keeps_backup(self):
        self.assertEqual(self.run_flow(), 0, self.output)
        self.assertIn("clean build", self.calls)
        self.assertIn("device install app", self.calls)
        self.assertIn("续期完成", self.output)
        self.assertFalse(self.ours.exists())
        backups = list(self.root.glob("Library/Application Support/CycleReminder/Renewal/profiles.*/*.mobileprovision"))
        self.assertEqual(len(backups), 1)

    def test_device_discovery_failures_keep_diagnostics_and_cache(self):
        for failure, message in [
            ("device-plugin", "Xcode 设备组件版本不匹配"),
            ("device-query", "Xcode device query failed"),
            ("no-device", "没有找到可用的 iPhone"),
        ]:
            with self.subTest(failure=failure):
                self.assertNotEqual(self.run_flow(failure), 0, self.output)
                self.assertIn(message, self.output)
                self.assertTrue(self.ours.exists())
                self.assertNotIn("clean build", self.calls)
                self.assertNotIn("device install", self.calls)
                if failure != "no-device":
                    self.assertNotIn("没有找到可用的 iPhone", self.output)

    def test_same_expiry_is_not_renewal(self):
        self.write_profile(self.root / "new.mobileprovision", self.old_expiry)
        self.assert_rejected("到期时间没有延长")

    def test_previous_app_expiry_is_checked_without_cached_profile(self):
        self.ours.unlink()
        app = self.root / "build/Build/Products/Debug-iphoneos/CycleReminder.app"
        app.mkdir(parents=True)
        self.write_profile(app / "embedded.mobileprovision", self.new_expiry)
        self.assertNotEqual(self.run_flow(), 0, self.output)
        self.assertIn("到期时间没有延长", self.output)
        self.assertNotIn("device install", self.calls)

    def test_expired_profile_can_be_renewed(self):
        self.write_profile(self.ours, self.now - datetime.timedelta(days=2))
        self.assertEqual(self.run_flow(), 0, self.output)
        self.assertIn("device install app", self.calls)

    def test_extension_of_only_one_day_is_rejected(self):
        self.write_profile(self.root / "new.mobileprovision", self.now + datetime.timedelta(days=2))
        self.assert_rejected("不足 6 天")

    def test_wrong_team_is_rejected(self):
        self.write_profile(self.root / "new.mobileprovision", self.new_expiry, team="OTHERTEAM")
        self.assert_rejected("Team 不符")

    def test_wrong_bundle_is_rejected(self):
        self.write_plist(self.root / "new-info.plist", {"CFBundleIdentifier": "com.example.wrong"})
        self.assert_rejected("App 标识与原安装不一致")

    def test_wrong_device_is_rejected(self):
        self.write_profile(self.root / "new.mobileprovision", self.new_expiry, device="another-phone")
        self.assert_rejected("不包含当前 iPhone")

    def test_missing_expiry_is_rejected(self):
        path = self.root / "new.mobileprovision"
        profile = plistlib.loads(path.read_bytes())
        del profile["ExpirationDate"]
        self.write_plist(path, profile)
        self.assert_rejected("无法读取描述文件到期时间")

    def test_build_failure_restores_cache(self):
        self.assertNotEqual(self.run_flow("build"), 0, self.output)
        self.assertTrue(self.ours.exists())
        self.assertNotIn("device install", self.calls)

    def test_restore_does_not_overwrite_new_download(self):
        self.assertNotEqual(self.run_flow("download-then-fail"), 0, self.output)
        self.assertEqual(self.ours.read_bytes(), (self.root / "new.mobileprovision").read_bytes())
        self.assertNotIn("device install", self.calls)

    def test_signature_failure_prevents_install(self):
        self.assertNotEqual(self.run_flow("signature"), 0, self.output)
        self.assertTrue(self.ours.exists())
        self.assertNotIn("device install", self.calls)

    def test_install_failure_restores_cache(self):
        self.assertNotEqual(self.run_flow("install"), 0, self.output)
        self.assertTrue(self.ours.exists())
        self.assertNotIn("✅", self.output)

    def test_launch_failure_does_not_claim_app_started_or_trust_issue(self):
        self.assertEqual(self.run_flow("launch"), 0, self.output)
        self.assertIn("自动启动未成功", self.output)
        self.assertNotIn("已重新安装并启动", self.output)
        self.assertNotIn("手机需要重新信任开发者", self.output)


if __name__ == "__main__":
    unittest.main()
