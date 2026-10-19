"""tools/changelog_draft.py: a release never stops for a missing "## New in x.y.z" section."""
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import changelog_draft as CD  # noqa: E402

LOG = "# Open Vanilla changelog\n(notes)\n\n## New in 1.0.0 (First)\n- The start.\n"


class ChangelogDraftTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, ignore_errors=True))

        def g(*a):
            subprocess.run(["git", *a], cwd=self.root, check=True, capture_output=True)
        g("init", "-q"); g("config", "user.email", "t@t"); g("config", "user.name", "t")
        with open(os.path.join(self.root, "CHANGELOG.md"), "w", encoding="utf-8") as f:
            f.write(LOG)
        g("add", "-A"); g("commit", "-qm", "Release 1.0.0"); g("tag", "v1.0.0")
        for msg in ("New logo on the website", "Changelog: 1.0.1 wording", "fix the queue window"):
            with open(os.path.join(self.root, "f.txt"), "a") as f:
                f.write(msg)
            g("add", "-A"); g("commit", "-qm", msg)

    def test_drafts_from_commits_since_the_last_release(self):
        wrote, lines = CD.ensure("1.0.1", root=self.root)
        self.assertTrue(wrote)
        self.assertEqual(lines, ["- Fix the queue window.", "- New logo on the website."])
        text = open(os.path.join(self.root, "CHANGELOG.md"), encoding="utf-8").read()
        self.assertTrue(CD.has_section(text, "1.0.1"))
        self.assertLess(text.index("## New in 1.0.1"), text.index("## New in 1.0.0"), "newest first")

    def test_an_existing_section_is_left_alone(self):
        CD.ensure("1.0.1", root=self.root)
        before = open(os.path.join(self.root, "CHANGELOG.md"), encoding="utf-8").read()
        self.assertEqual(CD.ensure("1.0.1", root=self.root), (False, []))
        self.assertEqual(open(os.path.join(self.root, "CHANGELOG.md"), encoding="utf-8").read(), before)


if __name__ == "__main__":
    unittest.main()
