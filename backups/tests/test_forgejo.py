#!/usr/bin/env python3
"""Exercise Forgejo backup/restore against disposable on-disk SQLite data."""
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ForgejoBackupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        (self.data / "gitea/conf").mkdir(parents=True)
        (self.data / "gitea/conf/app.ini").write_text("[security]\nSECRET_KEY = fixture\n")
        (self.data / "git/.ssh").mkdir(parents=True)
        (self.data / "git/.ssh/id_ed25519").write_text("fixture key\n")
        repo = self.data / "git/repositories/owner/example.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(repo)], check=True)
        self.db = sqlite3.connect(self.data / "gitea/gitea.db")
        self.addCleanup(self.db.close)
        self.db.executescript('PRAGMA journal_mode=WAL; CREATE TABLE "user" (id INTEGER); INSERT INTO "user" VALUES (1); CREATE TABLE repository (id INTEGER); INSERT INTO repository VALUES (1);')

    def run_backup(self, commands):
        env = dict(os.environ, BACKUPS_ROOT=str(self.root / "backups"), DATA_FIXTURE=str(self.data))
        return subprocess.run(
            ["bash", "-c", 'source "$1/lib/common.sh"; source "$1/config/forgejo.sh"; DATA_DIR="$DATA_FIXTURE"; ' + commands, "test", str(ROOT)],
            env=env, capture_output=True, text=True,
        )

    def test_online_wal_snapshot_restores_repos_and_secrets(self):
        result = self.run_backup("do_backup && do_restore_drill")
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list((self.root / "backups/forgejo").glob("*.tar.gz"))
        self.assertEqual(len(archives), 1)
        self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)
        with tarfile.open(archives[0]) as archive:
            names = archive.getnames()
            stamp = archives[0].name.removesuffix(".tar.gz")
            self.assertIn(f"{stamp}/gitea/conf/app.ini", names)
            self.assertIn(f"{stamp}/git/.ssh/id_ed25519", names)
        self.assertFalse(list(archives[0].parent.glob(".drill-*")))

    def test_missing_app_ini_fails_without_publishing_archive(self):
        (self.data / "gitea/conf/app.ini").unlink()
        result = self.run_backup("do_backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list((self.root / "backups/forgejo").glob("*.tar.gz")))

    def test_missing_database_is_not_created(self):
        self.db.close()
        (self.data / "gitea/gitea.db").unlink()
        result = self.run_backup("do_backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.data / "gitea/gitea.db").exists())

    def test_empty_database_fails_without_publishing_archive(self):
        self.db.close()
        (self.data / "gitea/gitea.db").write_bytes(b"")
        result = self.run_backup("do_backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list((self.root / "backups/forgejo").glob("*.tar.gz")))

    def test_drill_rejects_empty_repository_tree(self):
        shutil.rmtree(self.data / "git/repositories/owner/example.git")
        result = self.run_backup("do_backup && do_restore_drill")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository count mismatch", result.stderr)
        self.assertFalse(list((self.root / "backups/forgejo").glob(".drill-*")))

    def test_drill_rejects_database_with_zero_repositories(self):
        self.db.execute("DELETE FROM repository")
        self.db.commit()
        result = self.run_backup("do_backup && do_restore_drill")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restored database validation failed", result.stderr)

    def test_drill_does_not_count_wiki_as_missing_primary_repository(self):
        self.db.execute("INSERT INTO repository VALUES (2)")
        self.db.commit()
        wiki = self.data / "git/repositories/owner/example.wiki.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(wiki)], check=True)
        result = self.run_backup("do_backup && do_restore_drill")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository count mismatch", result.stderr)

    def test_drill_rejects_repository_enumeration_failure(self):
        result = self.run_backup(
            'do_backup || exit; find() { if [ "$1" = "$DEST" ]; then command find "$@"; else return 1; fi; }; do_restore_drill'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository enumeration failed", result.stderr)
        self.assertFalse(list((self.root / "backups/forgejo").glob(".drill-*")))


if __name__ == "__main__":
    unittest.main()
