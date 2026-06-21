# WeChat Linux Versions Archive

[![GitHub Release](https://img.shields.io/github/v/release/trouter-ai/wechat-linux-versions?sort=semver&display_name=release&style=for-the-badge&label=latest)](https://github.com/trouter-ai/wechat-linux-versions/releases)

The project uses GitHub Actions to automatically fetch the latest WeChat Linux packages, compute their checksums, and release all packages to this repository.

All releases are available in the [Releases](https://github.com/trouter-ai/wechat-linux-versions/releases) page.

## Notes

> Versions earlier than **4.1.1.7** were downloaded from web.archive.org, and some of them may have missing files.

## Development

### Workflow Local Testing

```bash
act workflow_dispatch --job archive_latest --input publish=false
# or
act workflow_dispatch --job archive_latest --input publish=false --container-architecture linux/amd64 --platform ubuntu-latest=catthehacker/ubuntu:act-latest
```
