#!/usr/bin/env python3
"""Audit an offline NeoStation database against original RetroArch playlists.

Never edits the input database, ROMs or playlists. --repair-copy prepares a
separate candidate and a full SQLite backup; it is NOT an on-device migration.
The source root must be the exact bookmark path established by the app's log.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import posixpath
import re
import sqlite3
import unicodedata
import urllib.parse
import zipfile


def nfc(value):
    return unicodedata.normalize('NFC', value)


def read_db(path):
    db = sqlite3.connect(pathlib.Path(path).resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise ValueError('Input SQLite integrity check failed')
    if db.execute('PRAGMA foreign_key_check').fetchall():
        raise ValueError('Input SQLite foreign key check failed')
    return db


def load_playlists(archive):
    entries = []
    builtins = {}
    with zipfile.ZipFile(archive) as z:
        for name in sorted(z.namelist()):
            if not name.startswith('playlists/') or not name.endswith('.lpl'):
                continue
            data = json.loads(z.read(name))
            if '/builtin/' in name:
                builtins[name] = data
                continue
            if name.count('/') != 1:
                continue
            for index, item in enumerate(data['items']):
                full = item['path']
                if not isinstance(full, str) or not full.startswith('~/Documents/'):
                    raise ValueError(f'Unsupported source path in {name}:{index}')
                # This is RetroArch archive notation, not a URL fragment.
                outer, marker, member = full.partition('#')
                if posixpath.normpath(outer) != outer or (marker and not member):
                    raise ValueError(f'Invalid relative path in {name}:{index}')
                key = hashlib.sha256(('retroarch-bookmark\0' + nfc(full)).encode()).hexdigest()
                def core(field):
                    value = item.get(field)
                    return data.get('default_' + field) if value in (None, '', 'DETECT') else value
                entries.append({'playlist':posixpath.basename(name), 'index':index,
                                'system':posixpath.basename(name)[:-4],
                                'path':full, 'outer':nfc(outer), 'member':member if marker else None,
                                'filename':member if marker else posixpath.basename(full),
                                'content_key':key, 'core_path':core('core_path'),
                                'core_name':core('core_name'), 'item':item})
    return entries, builtins


def merged_row(physical, virtual):
    result = dict(physical)
    conflicts = []
    for key, incoming in virtual.items():
        current = result[key]
        if key in ('rom_path', 'filename'):
            continue  # physical launch path/name retained; original fully archived
        if key == 'is_favorite':
            result[key] = int(bool(current) or bool(incoming))
        elif key == 'cloud_sync_enabled':
            result[key] = 0 if 0 in (current, incoming) else 1
        elif key == 'play_time':
            if (current or 0) > 0 and (incoming or 0) > 0:
                conflicts.append(key)  # sessions vs copied totals cannot be guessed
            else:
                result[key] = (current or 0) + (incoming or 0)
        elif key in ('created_at', 'updated_at', 'last_played'):
            values = [v for v in (current, incoming) if v]
            # Timestamp strings can use spaces or T; sorting a normalized copy
            # retains the exact original winning value.
            if values:
                from datetime import datetime
                try:
                    fn = min if key == 'created_at' else max
                    result[key] = fn(values, key=datetime.fromisoformat)
                except (ValueError, TypeError):
                    conflicts.append(key)
        elif current in (None, ''):
            result[key] = incoming
        elif incoming not in (None, '') and incoming != current:
            conflicts.append(key)
    return result, conflicts


def plan_repair(db, entries, source_root):
    root = nfc(source_root)
    match = re.fullmatch(r'(/(?:private/)?var/mobile/Containers/Data/Application/[0-9A-Fa-f-]+)/(Documents/.*)', root)
    if not match:
        raise ValueError('Use the exact iOS RetroArch bookmark root, not a guessed root')
    home, relative = match.groups()
    portable_root = '~/' + relative
    rows = [dict(r) for r in db.execute('SELECT * FROM user_roms')]
    metadata = {}
    if db.execute("SELECT name FROM sqlite_master WHERE name='user_screenscraper_metadata'").fetchone():
        metadata = {(r['app_system_id'], r['filename']): dict(r)
                    for r in db.execute('SELECT * FROM user_screenscraper_metadata')}
    by_path = collections.defaultdict(list)
    for row in rows:
        by_path[nfc(row['rom_path'])].append(row)
    by_export = collections.defaultdict(list)
    by_outer = collections.defaultdict(set)
    by_launch = collections.defaultdict(list)
    for entry in entries:
        by_export[(entry['system'],entry['filename'])].append(entry)
        by_outer[entry['outer']].add(entry['content_key'])
        by_launch[entry['filename']].append(entry)
    actions, unresolved = [], []
    used_targets = set()
    for row in rows:
        uri = urllib.parse.urlsplit(row['rom_path'])
        if uri.scheme != 'retroarch-library':
            continue
        segments = [urllib.parse.unquote(s) for s in uri.path.split('/') if s]
        if uri.netloc != 'game' or len(segments) != 2:
            unresolved.append({'path':row['rom_path'], 'reason':'unknown_virtual_identity'})
            continue
        candidates = by_export.get(tuple(segments), [])
        # An export filename lost source information when two playlist items
        # had the same filename. Never assign its user data to one arbitrarily.
        contents = {e['content_key'] for e in candidates}
        if len(contents) != 1:
            unresolved.append({'path':row['rom_path'], 'reason':'ambiguous_or_missing_playlist_entry','candidates':[e['path'] for e in candidates]})
            continue
        entry = candidates[0]
        if not entry['outer'].startswith(portable_root + '/'):
            unresolved.append({'path':row['rom_path'],'reason':'outside_authorized_source'})
            continue
        if len(by_outer[entry['outer']]) != 1:
            unresolved.append({'path':row['rom_path'],'reason':'archive_has_multiple_contents'})
            continue
        target = home + '/' + entry['outer'][2:]
        targets = by_path.get(target, [])
        if len(targets) != 1:
            unresolved.append({'path':row['rom_path'],'reason':'no_unique_physical_row','target':target})
            continue
        physical = targets[0]
        if physical['rom_path'] in used_targets:
            unresolved.append({'path':row['rom_path'],'reason':'target_already_claimed'})
            continue
        source_metadata = metadata.get((row['app_system_id'], row['filename']))
        target_metadata = metadata.get((physical['app_system_id'], physical['filename']))
        if row['filename'] != physical['filename'] and source_metadata:
            comparable = lambda r: {k:v for k,v in (r or {}).items() if k not in ('filename','updated_at')}
            if comparable(source_metadata) != comparable(target_metadata):
                unresolved.append({'path':row['rom_path'],'reason':'scraper_metadata_needs_merge','target':physical['rom_path']})
                continue
        merged, conflicts = merged_row(physical,row)
        if conflicts:
            unresolved.append({'path':row['rom_path'],'reason':'metadata_conflict','fields':conflicts,'target':physical['rom_path']})
            continue
        used_targets.add(physical['rom_path'])
        actions.append({'source':row,'target':physical,'merged':merged,'content_key':entry['content_key'],
                        'content_path':entry['path'],'memberships':[{'playlist':e['playlist'],'index':e['index']} for e in entries if e['content_key']==entry['content_key']]})
    return {'input_rows':len(rows),'source_root':source_root,'playlist_items':len(entries),
            'unique_contents':len({e['content_key'] for e in entries}),
            'actions':actions,'unresolved':unresolved,
            'ambiguous_launch_names':{k:[e['path'] for e in es] for k,es in by_launch.items() if len(es)>1},
            'warning':'Reference-level correspondence only; on-device archive members and file access remain unverified. The app must honor aliases before this copy can be deployed.'}


def apply_plan(db, plan):
    """Atomic, idempotent; rejects stale plans. Only acts on exact snapshots."""
    db.row_factory = sqlite3.Row
    changed = 0
    db.execute('BEGIN IMMEDIATE')
    try:
        db.execute('''CREATE TABLE IF NOT EXISTS user_retroarch_repair_v1 (
          source_path TEXT PRIMARY KEY, target_path TEXT NOT NULL,
          content_key TEXT NOT NULL, content_path TEXT NOT NULL,
          source_json TEXT NOT NULL, target_json TEXT NOT NULL,
          repaired_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)''')
        db.execute('''CREATE TABLE IF NOT EXISTS user_retroarch_membership_v1 (
          content_key TEXT NOT NULL, playlist TEXT NOT NULL,
          PRIMARY KEY(content_key, playlist))''')
        for action in plan['actions']:
            old, target = action['source'], action['target']
            a = db.execute('SELECT * FROM user_roms WHERE rom_path=?',(old['rom_path'],)).fetchone()
            b = db.execute('SELECT * FROM user_roms WHERE rom_path=?',(target['rom_path'],)).fetchone()
            archived = db.execute('SELECT * FROM user_retroarch_repair_v1 WHERE source_path=?',(old['rom_path'],)).fetchone()
            if a is None and archived and archived['content_key']==action['content_key'] and b is not None:
                continue
            if a is None or b is None or dict(a)!=old or dict(b)!=target:
                raise ValueError('Stale repair plan; user data changed, audit again')
            db.execute('INSERT INTO user_retroarch_repair_v1 (source_path,target_path,content_key,content_path,source_json,target_json) VALUES (?,?,?,?,?,?)',
                       (old['rom_path'],target['rom_path'],action['content_key'],action['content_path'],json.dumps(old,ensure_ascii=False),json.dumps(target,ensure_ascii=False)))
            for membership in action['memberships']:
                db.execute('INSERT OR IGNORE INTO user_retroarch_membership_v1 VALUES (?,?)',(action['content_key'],membership['playlist']))
            values = {k:v for k,v in action['merged'].items() if k!='rom_path'}
            db.execute('UPDATE user_roms SET '+','.join('"'+k+'"=?' for k in values)+' WHERE rom_path=?',[*values.values(),target['rom_path']])
            db.execute('DELETE FROM user_roms WHERE rom_path=?',(old['rom_path'],))
            changed += 1
        if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok' or db.execute('PRAGMA foreign_key_check').fetchall():
            raise ValueError('Post-repair integrity check failed')
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database',required=True)
    parser.add_argument('--playlists',required=True)
    parser.add_argument('--source-root',required=True)
    parser.add_argument('--report',required=True)
    parser.add_argument('--repair-copy')
    args=parser.parse_args()
    inputs = {pathlib.Path(args.database).resolve(), pathlib.Path(args.playlists).resolve()}
    outputs = [pathlib.Path(args.report).resolve()]
    if args.repair_copy:
        outputs += [pathlib.Path(args.repair_copy).resolve(), pathlib.Path(args.repair_copy).with_suffix('.original.sqlite').resolve()]
    if inputs.intersection(outputs) or len(set(outputs)) != len(outputs):
        raise ValueError('Output paths must be distinct and cannot overwrite inputs')
    with read_db(args.database) as db:
        entries,builtins=load_playlists(args.playlists)
        plan=plan_repair(db,entries,args.source_root)
        plan['builtin_playlists_preserved']={k:len(v['items']) for k,v in builtins.items()}
        plan['database_sha256']=hashlib.sha256(pathlib.Path(args.database).read_bytes()).hexdigest()
        plan['playlists_sha256']=hashlib.sha256(pathlib.Path(args.playlists).read_bytes()).hexdigest()
        if args.repair_copy:
            output=pathlib.Path(args.repair_copy)
            backup=output.with_suffix('.original.sqlite')
            if output.exists() or backup.exists():raise ValueError('Refusing to overwrite output or backup')
            if output.resolve()==pathlib.Path(args.database).resolve():raise ValueError('Input cannot be output')
            with sqlite3.connect(backup) as dest:db.backup(dest)
            with sqlite3.connect(output) as dest:
                db.backup(dest)
                plan['applied_on_copy']=apply_plan(dest,plan)
                plan['second_pass_changes']=apply_plan(dest,plan)
        pathlib.Path(args.report).write_text(json.dumps(plan,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({'rows':plan['input_rows'],'planned_merges':len(plan['actions']),
                          'unresolved':dict(collections.Counter(r['reason'] for r in plan['unresolved'])),
                          'launch_collisions':len(plan['ambiguous_launch_names'])},ensure_ascii=False))


if __name__=='__main__':main()
