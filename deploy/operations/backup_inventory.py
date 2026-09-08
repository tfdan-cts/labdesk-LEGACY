#!/usr/bin/env python3
"""Collect OCI backup metadata with the operator's existing OCI SDK and credentials."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-name', required=True)
    parser.add_argument('--compartment-id', help='defaults to configured tenancy root')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    temporary = None
    try:
        import oci
        config = oci.config.from_file()
        compartment = args.compartment_id or config['tenancy']
        compute = oci.core.ComputeClient(config, timeout=(5, 20))
        block = oci.core.BlockstorageClient(config, timeout=(5, 20))
        instances = oci.pagination.list_call_get_all_results(compute.list_instances, compartment).data
        matches = [item for item in instances if item.display_name == args.instance_name and item.lifecycle_state != 'TERMINATED']
        if len(matches) != 1:
            raise ValueError('instance name must resolve to exactly one instance')
        instance = matches[0]
        attachments = oci.pagination.list_call_get_all_results(
            compute.list_boot_volume_attachments, instance.availability_domain, compartment,
            instance_id=instance.id).data
        attached = [item for item in attachments if item.lifecycle_state == 'ATTACHED']
        if len(attached) != 1:
            raise ValueError('instance must have exactly one attached boot volume')
        volume_id = attached[0].boot_volume_id
        backups = oci.pagination.list_call_get_all_results(
            block.list_boot_volume_backups, compartment, boot_volume_id=volume_id).data
        evidence = {'observed_at': int(time.time()), 'boot_volume_id': volume_id, 'backups': [
            {'id': item.id, 'state': item.lifecycle_state, 'created_at': item.time_created.timestamp(),
             'expires_at': item.expiration_time.timestamp() if item.expiration_time else None}
            for item in backups]}
        if args.output.is_symlink():
            raise ValueError('output must not be a symlink')
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=args.output.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.chmod(temporary, 0o600)
            json.dump(evidence, stream, sort_keys=True)
            stream.write('\n')
        os.replace(temporary, args.output)
        temporary = None
        print(json.dumps({'inventory_written': True, 'backup_count': len(backups)}))
        return 0
    except Exception as error:
        print(json.dumps({'inventory_written': False, 'error_type': type(error).__name__}))
        return 1
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    raise SystemExit(main())
