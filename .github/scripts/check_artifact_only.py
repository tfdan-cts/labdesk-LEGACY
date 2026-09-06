#!/usr/bin/env python3
"""Verify artifact-only builds cannot publish releases. Requires PyYAML."""

from pathlib import Path
import yaml


def check(build, dispatch, ci):
    # BaseLoader preserves GitHub's `on` key instead of YAML 1.1's boolean True.
    assert build["on"]["workflow_call"]["inputs"]["publish-release"]["default"] == "true"
    assert dispatch["jobs"]["run"]["with"]["publish-release"] == "${{ inputs.publish-release }}"
    assert ci["jobs"]["run-ci"]["with"]["publish-release"] == "false"
    publishers = [step for job in build["jobs"].values() for step in job.get("steps", [])
                  if step.get("uses", "").startswith("softprops/action-gh-release@")]
    assert publishers, "No release steps found: inspect the workflow before changing this check"
    for step in publishers:
        guard = step.get("if", "")
        assert guard == "inputs.publish-release" or guard.endswith(" && inputs.publish-release"), step["name"]
    assert build["jobs"]["release-manifest"]["if"].endswith(" && inputs.publish-release")
    return len(publishers)


if __name__ == "__main__":
    workflows = Path(__file__).resolve().parents[1] / "workflows"
    docs = [yaml.load((workflows / name).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
            for name in ["flutter-build.yml", "labdesk-dispatch.yml", "flutter-ci.yml"]]
    count = check(*docs)
    print(f"Artifact-only publication gates verified for {count} release steps")
