# WeChat Linux Version Archive

The project uses GitHub Actions to automatically fetch the latest WeChat Linux packages, compute their checksums, and release all packages to this repository.

## Notes

> Versions earlier than 4.1.1.7 were downloaded from web.archive.org, and some of them may have missing files.

## Development

### Local Testing Workflow

```bash
act workflow_dispatch --input publish=false
# or
act workflow_dispatch --input publish=false -P ubuntu-latest=catthehacker/ubuntu:act-latest --container-architecture linux/amd64
```
