"""Encrypt delivery artifacts and secret-bearing compilation caches before upload."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
CACHE_PATHS=['ios','build/ios/DolphinDerivedData','build/stikjit-current',
 'build/ios/Release-iphoneos','build/native_assets',
 'packages/neo_swap/ios/Classes/Storage','packages/neo_swap/ios/Classes/Relay',
 'packages/neo_swap/ios/Classes/Donation',
 'build/dolphin-ci','build/fast-native','build/ruby-gems','.dart_tool',
 'packages/dolphin_internal_bridge/ios/Frameworks','packages/dolphin_internal_bridge/ios/TouchResources',
 'packages/stikjit_bridge/ios/Frameworks','packages/dolphin_jit_helper/ios/Frameworks',
 'packages/rpcs3_internal_bridge/ios/Frameworks','dist/armsx2','dist/dusklight',
 'dist/kartpad-native','dist/rpcs3-native','dist/libretro']

def run(*args,**kwargs):
    subprocess.run([str(x) for x in args],check=True,**kwargs)

def digest(path,key):
    value=hmac.new(key,digestmod=hashlib.sha256)
    with path.open('rb') as handle:
        for block in iter(lambda:handle.read(1024*1024),b''): value.update(block)
    return value.hexdigest()

def aes(source,dest,password,decrypt=False):
    run('openssl','enc','-aes-256-cbc','-d' if decrypt else '-e',
        '-pbkdf2','-iter','200000','-salt','-pass','file:'+str(password),
        '-in',source,'-out',dest)

def cache(unpack=False):
    secret=os.environ.get('SCREENSCRAPER_DEV_PASSWORD','')
    if not secret: raise ValueError('Missing authorized cache encryption secret')
    context='NeoStation device cache v1:'+os.environ['GITHUB_SHA']+':'+os.environ['BUILD_NUMBER']
    key=hmac.new(secret.encode(),context.encode(),hashlib.sha256).digest()
    folder=ROOT/'.ci-cache';folder.mkdir(exist_ok=True)
    blob=folder/'device-state.enc'
    with tempfile.TemporaryDirectory() as temp:
        temp=Path(temp);password=temp/'password';password.write_text(key.hex())
        packed=temp/'state.tar.zst';raw=temp/'state.tar'
        if unpack:
            expected=json.loads((folder/'authentication.json').read_text())
            if not hmac.compare_digest(expected['hmacSha256'],digest(blob,key)):
                raise ValueError('Compilation cache authentication failed')
            aes(blob,packed,password,decrypt=True)
            run('zstd','-d','-f',packed,'-o',raw)
            run('tar','-xf',raw,'-C',ROOT)
        else:
            existing=[p for p in CACHE_PATHS if (ROOT/p).exists()]
            run('tar','-cf',raw,*existing,cwd=ROOT)
            run('zstd','-1','-T0','-f',raw,'-o',packed)
            aes(packed,blob,password)
            (folder/'authentication.json').write_text(json.dumps({'hmacSha256':digest(blob,key)}))

def artifact(source,destination):
    destination.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp=Path(tmp);password=tmp/'password';raw=tmp/'artifact.tar'
        password.write_text(os.urandom(32).hex())
        run('tar','-cf',raw,'-C',source,'.')
        aes(raw,destination/'artifact.tar.enc',password)
        run('openssl','pkeyutl','-encrypt','-pubin','-inkey',ROOT/os.environ.get('DELIVERY_RECIPIENT','build-utils/delivery-422-recipient.pem'),
            '-in',password,'-out',destination/'password.rsa',
            '-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha256')
    # No plaintext credentials, application binary or cache is uploaded.
    (destination/'format.json').write_text(json.dumps({'cipher':'AES-256-CBC PBKDF2 200000',
        'keyEnvelope':'RSA OAEP SHA256','content':'tar','publication':'encrypted delivery only'}))

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('operation',choices=['cache-pack','cache-unpack','artifact'])
    parser.add_argument('source',nargs='?',type=Path)
    parser.add_argument('destination',nargs='?',type=Path)
    args=parser.parse_args()
    if args.operation=='artifact': artifact(args.source,args.destination)
    else: cache(args.operation=='cache-unpack')
