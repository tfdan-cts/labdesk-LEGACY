#!/usr/bin/env python3
"""Read-only labnet probes. JSON/exit status is input for the existing monitor."""
import argparse
import http.client
import ipaddress
import json
import math
import os
import re
from pathlib import Path
import secrets
import socket
import ssl
import stat
import struct
import time


def check_http(connection, path, expected_status, body_kind=None, token=None):
    try:
        headers = {'Authorization': 'Token ' + token} if token else {}
        connection.request('GET', path, headers=headers)
        response = connection.getresponse()
        if response.status != expected_status:
            raise ValueError('unexpected HTTP status ' + str(response.status))
        if body_kind:
            body = response.read(2 * 1024 * 1024 + 1)
            if len(body) > 2 * 1024 * 1024:
                raise ValueError('response too large')
            try:
                value = json.loads(body)
            except (ValueError, UnicodeError):
                raise ValueError('invalid JSON response') from None
            if body_kind == 'healthy' and (not isinstance(value, dict) or value.get('ok') is not True):
                raise ValueError('broker reports unhealthy')
            if body_kind == 'peers' and not isinstance(value, list):
                raise ValueError('invalid peers response')
        return {'http_status': response.status}
    finally:
        connection.close()


def check_stun(host, port=3478, timeout=5):
    transaction = secrets.token_bytes(12)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.send(struct.pack('!HHI', 0x0001, 0, 0x2112a442) + transaction)
        response = sock.recv(4096)
    if len(response) < 20:
        raise ValueError('short STUN response')
    kind, length, cookie = struct.unpack('!HHI', response[:8])
    if (kind, cookie, response[8:20]) != (0x0101, 0x2112a442, transaction) or length != len(response) - 20 or length % 4:
        raise ValueError('invalid STUN binding response')
    offset, mapped = 20, False
    while offset < len(response):
        if offset + 4 > len(response):
            raise ValueError('truncated STUN attribute')
        attribute, size = struct.unpack('!HH', response[offset:offset + 4])
        offset += 4
        if offset + size > len(response):
            raise ValueError('truncated STUN value')
        if attribute in (0x0001, 0x0020) and size == 8 and response[offset:offset + 2] == b'\x00\x01':
            port_value = struct.unpack('!H', response[offset + 2:offset + 4])[0]
            mapped = (port_value ^ (0x2112 if attribute == 0x0020 else 0)) != 0
        offset += (size + 3) & ~3
    if not mapped:
        raise ValueError('missing STUN mapped address')
    return {'binding_response': True}


def timestamp(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('invalid timestamp')
    return value


def check_backup(path, volume_id, max_age, evidence_max_age, now=None):
    if not path or not volume_id:
        raise ValueError('backup evidence and volume are not configured')
    now = time.time() if now is None else now
    evidence = json.loads(Path(path).read_text(encoding='utf-8'))
    observed = timestamp(evidence['observed_at'])
    if not 0 <= now - observed <= evidence_max_age:
        raise ValueError('backup inventory stale or future dated')
    if evidence['boot_volume_id'] != volume_id or not volume_id:
        raise ValueError('backup inventory belongs to another volume')
    backups = evidence['backups']
    available = []
    for backup in backups:
        created = timestamp(backup['created_at'])
        if not isinstance(backup['id'], str) or not backup['id'].strip() or created > observed:
            raise ValueError('invalid backup identity or creation time')
        expiry = backup['expires_at']
        if backup['state'] == 'AVAILABLE' and (expiry is None or timestamp(expiry) > now):
            available.append(backup)
    if not available:
        raise ValueError('no available unexpired backup')
    newest = max(available, key=lambda item: item['created_at'])
    if now - newest['created_at'] > max_age:
        raise ValueError('backup older than configured threshold')
    if any(item['created_at'] >= newest['created_at'] and item['state'] == 'FAULTY' for item in backups):
        raise ValueError('backup failed after latest available restore point')
    return {'age_seconds': round(now - newest['created_at']), 'restoration_proven': False}


def validate_config(config):
    required = {'mode', 'broker_host', 'netbird_host', 'netbird_connect_ip', 'token_file',
                'timeout_seconds', 'tls_min_days', 'backup_evidence', 'boot_volume_id',
                'backup_max_age_seconds', 'evidence_max_age_seconds'}
    if not isinstance(config, dict) or set(config) != required:
        raise ValueError('configuration keys do not match contract')
    if config['mode'] not in ('public', 'operator'):
        raise ValueError('invalid mode')
    for key in ('broker_host', 'netbird_host'):
        if not isinstance(config[key], str) or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', config[key]):
            raise ValueError('invalid host')
    for key, maximum in (('timeout_seconds', 10), ('tls_min_days', 90),
                         ('backup_max_age_seconds', 31 * 86400), ('evidence_max_age_seconds', 3600)):
        if isinstance(config[key], bool) or not isinstance(config[key], (int, float)) or not 0 < config[key] <= maximum:
            raise ValueError('invalid threshold')
    for key in ('backup_evidence', 'boot_volume_id', 'token_file'):
        if config[key] is not None and (not isinstance(config[key], str) or not config[key].strip()):
            raise ValueError('invalid file or volume reference')
    if config['netbird_connect_ip'] is not None:
        ipaddress.ip_address(config['netbird_connect_ip'])
    if config['mode'] == 'public' and (config['token_file'] is not None or config['netbird_connect_ip'] is not None):
        raise ValueError('public mode requires external DNS and no token')
    if config['mode'] == 'operator' and not config['token_file']:
        raise ValueError('operator mode requires a token file')


def tls_connection(host, connect_ip, timeout):
    connection = http.client.HTTPSConnection(host, timeout=timeout)
    raw = socket.create_connection((connect_ip or host, 443), timeout=timeout)
    try:
        connection.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    except Exception:
        raw.close()
        raise
    return connection


def check_tls(host, connect_ip, timeout, min_days):
    connection = tls_connection(host, connect_ip, timeout)
    try:
        days = (ssl.cert_time_to_seconds(connection.sock.getpeercert()['notAfter']) - time.time()) / 86400
        if days < min_days:
            raise ValueError('certificate expires within threshold')
        return {'days_remaining': round(days, 1)}
    finally:
        connection.close()


def read_token(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('token must be a regular file')
    mode = stat.S_IMODE(info.st_mode)
    credential_directory = os.environ.get('CREDENTIALS_DIRECTORY')
    systemd_copy = (credential_directory and mode == 0o440 and path.is_absolute()
                    and path.parent == Path(credential_directory)
                    and path.parent == Path(credential_directory).resolve())
    if os.name != 'nt' and mode & 0o077 and not systemd_copy:
        raise ValueError('token file must be private')
    token = path.read_text(encoding='utf-8').strip()
    if not token or '\n' in token or '\r' in token:
        raise ValueError('invalid token file')
    return token


def run_checks(config):
    results = []

    def probe(name, action):
        try:
            results.append({'check': name, 'ok': True, 'detail': action()})
        except Exception as error:
            # Response bodies, URLs, credentials and arbitrary exception text never enter logs.
            failure = {'check': name, 'ok': False, 'error_type': type(error).__name__}
            if type(error) is ValueError:
                failure['reason'] = str(error)
            results.append(failure)

    timeout = config['timeout_seconds']
    broker, netbird = config['broker_host'], config['netbird_host']
    connect_ip = config['netbird_connect_ip']
    for name, host, ip in (('broker_tls', broker, None), ('netbird_tls', netbird, connect_ip)):
        probe(name, lambda host=host, ip=ip: check_tls(host, ip, timeout, config['tls_min_days']))
    probe('broker_health', lambda: check_http(tls_connection(broker, None, timeout), '/health', 200, 'healthy'))
    probe('broker_auth_fence', lambda: check_http(tls_connection(broker, None, timeout), '/console/org', 401))
    probe('relay_router', lambda: check_http(tls_connection(netbird, connect_ip, timeout), '/relay', 426))
    probe('stun_binding', lambda: check_stun(netbird, timeout=timeout))
    if config['mode'] == 'operator':
        def api():
            token = read_token(config['token_file'])
            return check_http(tls_connection(netbird, connect_ip, timeout), '/api/peers', 200, 'peers', token)
        probe('netbird_authenticated_api', api)
        probe('netbird_auth_fence', lambda: check_http(tls_connection(netbird, connect_ip, timeout), '/api/peers', 401))
    else:
        probe('netbird_public_fence', lambda: check_http(tls_connection(netbird, None, timeout), '/api/peers', 403))
    probe('backup_inventory', lambda: check_backup(config['backup_evidence'], config['boot_volume_id'],
          config['backup_max_age_seconds'], config['evidence_max_age_seconds']))
    return {'observed_at': int(time.time()), 'mode': config['mode'], 'ok': all(item['ok'] for item in results),
            'checks': results, 'transport_tested': False, 'restoration_tested': False, 'alert_delivery_tested': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--check-config', action='store_true', help='parse only; no network or credentials')
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding='utf-8'))
        validate_config(config)
    except Exception as error:
        print(json.dumps({'config_valid': False, 'error_type': type(error).__name__}))
        return 2
    if args.check_config:
        print(json.dumps({'config_valid': True, 'backup_configured': bool(config['backup_evidence'] and config['boot_volume_id'])}))
        return 0
    result = run_checks(config)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
