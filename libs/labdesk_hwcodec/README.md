# labdesk_hwcodec

Hardware video encoding and decoding for LabDesk Connect: FFmpeg with NVIDIA
NVENC/NVDEC, AMD AMF and Intel VPL, plus the direct-to-GPU (`vram`) path on
Windows. `LABDESK_HWCODEC_NVENC_GPU` selects the NVENC GPU index when a machine
has more than one.

Derived from the `hwcodec` crate at
https://github.com/rustdesk-org/hwcodec commit
778df1f99597722473b29443bac22ae6c23946fe, with its `externals` submodule
(https://github.com/rustdesk-org/externals) vendored: only the AMF, Intel
MediaSDK/VPL, NVIDIA Video Codec SDK interface and nv-codec-headers trees the
build script reads are kept. Development tools and examples are not carried.
The codec paths, build flags and static CRT linkage are unchanged, so encoding
and decoding performance is the same as the upstream crate. Third-party license
terms for the vendored SDK headers are listed in `docs/THIRD-PARTY.md`.