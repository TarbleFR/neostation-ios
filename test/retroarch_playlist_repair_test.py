import importlib.util
import pathlib
import sqlite3
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('repair',ROOT/'tools/retroarch_playlist_repair.py')
repair=importlib.util.module_from_spec(spec);spec.loader.exec_module(repair)

class RepairTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:');self.db.row_factory=sqlite3.Row
        self.db.execute('CREATE TABLE user_roms (rom_path TEXT PRIMARY KEY,filename TEXT,app_system_id TEXT,is_favorite INTEGER,play_time INTEGER,description TEXT)')
        self.old={'rom_path':'retroarch-library://game/GBA/Game.gba','filename':'Game.gba','app_system_id':'gba','is_favorite':1,'play_time':25,'description':'Keep'}
        self.target={'rom_path':'/source/Game.zip','filename':'Game.zip','app_system_id':'gba','is_favorite':0,'play_time':0,'description':None}
        for row in [self.old,self.target]:self.db.execute('INSERT INTO user_roms VALUES (?,?,?,?,?,?)',list(row.values()))
        self.db.commit()
        merged,conflicts=repair.merged_row(self.target,self.old);self.assertEqual(conflicts,[])
        self.plan={'actions':[{'source':self.old,'target':self.target,'merged':merged,'content_key':'full-path-and-member-key','content_path':'~/Documents/Game.zip#Game.gba','memberships':[{'playlist':'One.lpl'},{'playlist':'Two.lpl'}]}]}
    def tearDown(self):self.db.close()
    def test_backup_metadata_memberships_and_idempotence(self):
        self.assertEqual(repair.apply_plan(self.db,self.plan),1)
        row=dict(self.db.execute('SELECT * FROM user_roms').fetchone())
        self.assertEqual(row['rom_path'],self.target['rom_path']);self.assertEqual(row['is_favorite'],1);self.assertEqual(row['play_time'],25);self.assertEqual(row['description'],'Keep')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM user_retroarch_membership_v1').fetchone()[0],2)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM user_retroarch_repair_v1').fetchone()[0],1)
        self.assertEqual(repair.apply_plan(self.db,self.plan),0)
    def test_stale_plan_rolls_back(self):
        self.db.execute('UPDATE user_roms SET play_time=99 WHERE rom_path=?',(self.target['rom_path'],));self.db.commit()
        with self.assertRaises(ValueError):repair.apply_plan(self.db,self.plan)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM user_roms').fetchone()[0],2)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='user_retroarch_repair_v1'").fetchone()[0],0)
    def test_sql_error_rolls_back_backup_and_data(self):
        self.db.execute("CREATE TRIGGER fail BEFORE DELETE ON user_roms BEGIN SELECT RAISE(ABORT,'injected'); END")
        with self.assertRaises(sqlite3.IntegrityError):repair.apply_plan(self.db,self.plan)
        self.assertEqual([dict(r) for r in self.db.execute('SELECT * FROM user_roms')],[self.old,self.target])
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='user_retroarch_repair_v1'").fetchone()[0],0)
    def test_conflicting_history_and_system_are_not_combined(self):
        target={**self.target,'play_time':25,'app_system_id':'different'}
        _,conflicts=repair.merged_row(target,self.old)
        self.assertEqual(set(conflicts),{'play_time','app_system_id'})
    def test_full_path_identity_not_title_or_filename(self):
        # Canonical equivalence preserves accents, trailing spaces and case.
        self.assertEqual(repair.nfc('Bibliothe\u0300ques '),'Bibliothèques ')
        self.assertNotEqual(repair.nfc('Bibliothèques '),repair.nfc('Bibliothèques'))
        self.assertNotEqual(repair.nfc('A/Game.gba'),repair.nfc('B/Game.gba'))
        self.assertNotEqual(repair.nfc('Game.zip#A.gba'),repair.nfc('Game.zip#B.gba'))

if __name__=='__main__':unittest.main()
