#!/usr/bin/env python3
"""Build and smoke-test security images with disposable, isolated fixtures."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--project', default='web3signer-security')
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
project = args.project
prefix = 'web3signer-security-test-' + uuid.uuid4().hex[:8]
network = prefix + '-net'
containers = []
node = 'node:24.22.1-alpine3.24'
results = {}


def docker(*cmd, check=True, timeout=120, binary=False):
    p = subprocess.run(['docker', *cmd], capture_output=True, text=not binary, timeout=timeout, cwd=ROOT)
    if check and p.returncode:
        message = p.stderr.decode(errors='replace') if binary else p.stderr
        raise RuntimeError('docker ' + cmd[0] + ': ' + message[-3000:])
    return p.stdout if binary else p.stdout.strip()


def start(suffix, image, command=(), options=()):
    name = prefix + '-' + suffix
    containers.append(name)
    docker('run', '-d', '--name', name, '--network', network, '--network-alias', suffix,
           '--cpus', '1', '--memory', '1g', *options, image, *command)
    return name


def wait(fn):
    deadline = time.monotonic() + 90
    while True:
        try:
            return fn()
        except (AssertionError, RuntimeError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(.5)


def http(url):
    script = ('fetch(' + json.dumps(url) + ',{signal:AbortSignal.timeout(3000)})'
              '.then(async r=>{if(!r.ok)throw Error(r.status);console.log(await r.text())})'
              '.catch(e=>{console.error(e.message);process.exit(1)})')
    return docker('run', '--rm', '--network', network, '--cpus', '.5', '--memory', '128m',
                  '--entrypoint', 'node', node, '-e', script)


try:
    for variant in ('mainnet', 'gnosis', 'hoodi', 'lukso'):
        docker('compose', '-f', 'docker-compose.yml', '-f', f'package_variants/{variant}/docker-compose.yml',
               '-p', project, 'config', '--quiet')
    if not args.skip_build:
        docker('compose', '-f', 'docker-compose.yml', '-f', 'package_variants/mainnet/docker-compose.yml',
               '-p', project, 'build', 'tracker', 'web3signer', 'flyway', timeout=1800)
    images = {service: project + '-' + service for service in ('tracker', 'web3signer', 'flyway')}
    blocked_keys = {
        'bd153ed7b0434f6886b17bce8bbe84ed340c7132d702a8f4fa318f756ecbd6f3',
        'c619e4780ed8e0abeda24ad732567de4383a7ea941338f6d1a7d1b49ac792fe9',
        '8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782',
    }
    results['osTrust'] = {}
    for service, image in images.items():
        bundle = docker('run', '--rm', '--network', 'none', '--entrypoint', 'cat', image,
                        '/etc/ssl/certs/ca-certificates.crt')
        certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', bundle, re.S)
        assert len(certs) >= 80
        for cert in certs:
            key = subprocess.run(['openssl', 'x509', '-pubkey', '-noout'], input=cert.encode(),
                                 capture_output=True, check=True).stdout
            der = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=key,
                                 capture_output=True, check=True).stdout
            assert hashlib.sha256(der).hexdigest() not in blocked_keys, service
        results['osTrust'][service] = {'certificates': len(certs), 'incidentKeysAbsent': True}
    for service, minimum in [('web3signer', (25, 0, 5)), ('flyway', (21, 0, 13))]:
        image = images[service]
        release = docker('run', '--rm', '--network', 'none', '--entrypoint', 'cat', image,
                         '/opt/java/openjdk/release')
        found = re.search(r'^JAVA_VERSION="(\d+)\.(\d+)\.(\d+)', release, re.M)
        assert found and tuple(map(int, found.groups())) >= minimum, release
        trust = docker('run', '--rm', '--network', 'none', '--entrypoint', 'keytool', image,
                       '-J-Duser.language=en', '-J-Duser.country=US', '-list', '-v',
                       '-cacerts', '-storepass', 'changeit')
        owners = [line for line in trust.splitlines() if line.startswith('Owner:')]
        assert len(owners) >= 80, 'Unexpectedly empty Java trust store'
        for root in ('emSign ECC Root CA - G3', 'AAA Certificate Services',
                     'emSign Root CA - G1', 'emSign Root CA - G2'):
            assert not any('CN=' + root in owner for owner in owners), root
        results[service] = {'java': '.'.join(found.groups()), 'javaTrustRoots': len(owners),
                            'fourDistrustedRootsAbsent': True}

    # Compile the cleanup helper as in production and exercise real JKS/PKCS12 stores.
    helper = project + '-java-ca-helper'
    compose_config = json.loads(docker('compose', '-f', 'docker-compose.yml', '-f',
                                       'package_variants/mainnet/docker-compose.yml',
                                       '-p', project, 'config', '--format', 'json'))
    signer_version = compose_config['services']['web3signer']['build']['args']['WEB3SIGNER_VERSION']
    docker('build', '--target', 'java-ca-helper', '--build-arg', 'WEB3SIGNER_VERSION=' + signer_version,
           '-t', helper, 'services/web3signer', timeout=600)
    docker('run', '--rm', '--network', 'none', '--cpus', '1', '--memory', '512m', '--tmpfs', '/tmp',
           '-v', str(ROOT / 'tests') + ':/tests:ro', helper, 'sh', '/tests/test-root-cleanup.sh')
    assert (ROOT / 'services/web3signer/RemoveDistrustedRoots.java').read_bytes() == \
           (ROOT / 'services/flyway/RemoveDistrustedRoots.java').read_bytes()
    results['rootCleanupFixtures'] = {'JKS': True, 'PKCS12': True, 'idempotent': True,
                                     'unrelatedRootPreserved': True, 'smallStoreRejected': True}

    holder = prefix + '-binary'
    containers.append(holder)
    docker('create', '--name', holder, '--network', 'none', images['tracker'])
    with tarfile.open(fileobj=io.BytesIO(docker('cp', holder + ':/app/validator-tracker', '-', binary=True))) as archive:
        binary = archive.extractfile(next(m for m in archive if m.isfile())).read()
    offset = binary.index(b'\xff Go buildinf:')
    assert binary[offset + 15] & 2
    assert binary[offset + 33:offset + 41] == b'go1.27.3', 'Wrong tracker toolchain'
    config = json.loads(docker('image', 'inspect', images['tracker']))[0]['Config']
    assert 'GODEBUG=multipathtcp=0' in config['Env']
    results['trackerBuild'] = {'go': '1.27.3', 'mptcpDefaultDisabled': True}

    docker('network', 'create', '--internal', network)
    mock_script = """const http=require('http');let hits={};const root='0x'+'11'.repeat(32);
http.createServer((q,r)=>{if(q.url==='/fixture-stats'){r.end(JSON.stringify(hits));return}
hits[q.url]=(hits[q.url]||0)+1;let data={};
if(q.url.includes('genesis'))data={genesis_time:'1606824023',genesis_validators_root:root,genesis_fork_version:'0x00000000'};
else if(q.url.includes('/config/spec'))data={CONFIG_NAME:'mainnet',SECONDS_PER_SLOT:'12',SLOTS_PER_EPOCH:'32',DEPOSIT_CHAIN_ID:'1',DEPOSIT_NETWORK_ID:'1',GENESIS_FORK_VERSION:'0x00000000',ALTAIR_FORK_VERSION:'0x01000000',BELLATRIX_FORK_VERSION:'0x02000000',CAPELLA_FORK_VERSION:'0x03000000',DENEB_FORK_VERSION:'0x04000000',ELECTRA_FORK_VERSION:'0x05000000',FULU_FORK_VERSION:'0x06000000',MIN_GENESIS_TIME:'1606824000',GENESIS_DELAY:'172800',DEPOSIT_CONTRACT_ADDRESS:'0x'+'00'.repeat(20)};
else if(q.url.includes('/node/version'))data={version:'security-fixture'};
else if(q.url.includes('finality_checkpoints'))data={previous_justified:{epoch:'1',root},current_justified:{epoch:'1',root},finalized:{epoch:'1',root}};
else if(q.url.includes('syncing'))data={head_slot:'32',sync_distance:'0',is_syncing:false,is_optimistic:false,el_offline:false};
r.setHeader('Content-Type','application/json');r.end(JSON.stringify(q.url.includes('/brain/validators')?{}:{data}));}).listen(5052)"""
    start('mock', node, ['-e', mock_script], ['--entrypoint', 'node'])
    env = ['NETWORK=mainnet', 'BEACON_ENDPOINT=http://mock:5052', 'BRAIN_URL=http://mock:5052',
           'DAPPMANAGER_ENDPOINT=http://mock:5052', 'NOTIFIER_URL=http://mock:5052',
           'DUTIES_CHECKER_POLL_INTERVAL_SECONDS=1']
    tracker = start('tracker', images['tracker'], options=[x for e in env for x in ('-e', e)])
    def tracker_ready():
        assert docker('inspect', '--format', '{{.State.Running}}', tracker) == 'true'
        hits = json.loads(http('http://mock:5052/fixture-stats'))
        assert '/eth/v1/node/version' in hits and any('finality_checkpoints' in key for key in hits)
        return hits
    before_restart = wait(tracker_ready)
    docker('restart', tracker)
    def tracker_restarted():
        hits = tracker_ready()
        assert hits['/eth/v1/node/version'] > before_restart['/eth/v1/node/version']
    wait(tracker_restarted)
    results['trackerSmoke'] = {'mockBeaconInitialization': True, 'restart': True}

    signer = start('signer', images['web3signer'], ['-c', 'mkdir -p /tmp/empty-keys; exec /opt/web3signer/bin/web3signer --key-store-path=/tmp/empty-keys --http-listen-host=0.0.0.0 --http-listen-port=9000 --http-host-allowlist="*" eth2 --slashing-protection-enabled=false --network=mainnet'],
                   ['--entrypoint', 'sh', '-e', 'JAVA_OPTS=-Xmx512m'])
    def signer_ready():
        assert json.loads(http('http://signer:9000/api/v1/eth2/publicKeys')) == []
        http('http://signer:9000/healthcheck')
    wait(signer_ready)
    docker('restart', signer)
    wait(signer_ready)
    results['signerSmoke'] = {'emptyKeyApi': True, 'healthcheck': True, 'restart': True}

    db = start('db', 'postgres:14-alpine', options=['-e', 'POSTGRES_PASSWORD=security-test',
                                                 '-e', 'POSTGRES_DB=web3signer'])
    wait(lambda: docker('exec', db, 'pg_isready', '-U', 'postgres'))
    migration = ['run', '--rm', '--network', network, '--cpus', '1', '--memory', '768m',
                 '--entrypoint', '/flyway/flyway', images['flyway'],
                 '-url=jdbc:postgresql://db:5432/web3signer', '-user=postgres',
                 '-password=security-test', 'migrate']
    docker(*migration)
    assert 'up to date' in docker(*migration).lower()
    count = int(docker('exec', db, 'psql', '-U', 'postgres', '-d', 'web3signer', '-Atc',
                       "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"))
    assert count >= 7, count
    results['flywaySmoke'] = {'freshMigration': True, 'repeatMigrationNoChanges': True, 'publicTables': count}
    print(json.dumps(results, indent=2))
finally:
    for name in reversed(containers):
        docker('rm', '-f', '-v', name, check=False)
    docker('network', 'rm', network, check=False)
