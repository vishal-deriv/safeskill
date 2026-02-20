"""Config directory initialization helper."""

from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

import structlog

logger = structlog.get_logger(__name__)


def _find_bundled_config() -> Path | None:
    """Find the bundled config directory, checking multiple locations."""
    candidates = [
        # Running from source checkout (development / git clone)
        Path(__file__).parent.parent / "config",
        # Installed via pip from /opt/safeskill/src
        Path("/opt/safeskill/src/config"),
        # Relative to the safeskill package itself
        Path(__file__).parent / "config",
    ]

    # Also check SAFESKILL_INSTALL_DIR if set
    install_dir = os.environ.get("SAFESKILL_INSTALL_DIR")
    if install_dir:
        candidates.insert(0, Path(install_dir) / "config")

    for candidate in candidates:
        if candidate.exists() and (candidate / "base-policy.yaml").exists():
            return candidate

    return None


def initialize_config(config_dir: str) -> None:
    """Copy bundled default configs to the target config directory."""
    target = Path(config_dir)
    target.mkdir(parents=True, exist_ok=True)

    environments_dir = target / "environments"
    environments_dir.mkdir(parents=True, exist_ok=True)

    bundled = _find_bundled_config()
    if bundled is None:
        logger.error(
            "bundled_config_not_found",
            searched=[
                str(Path(__file__).parent.parent / "config"),
                "/opt/safeskill/src/config",
            ],
            hint="Set SAFESKILL_INSTALL_DIR to the project root",
        )
        return

    logger.info("bundled_config_found", path=str(bundled))

    files_to_copy = [
        "base-policy.yaml",
        "runtime-policy.yaml",
        "signatures.yaml",
    ]
    env_files = ["dev.yaml", "staging.yaml", "production.yaml"]
    copied = 0

    for filename in files_to_copy:
        src = bundled / filename
        dst = target / filename
        if src.exists():
            shutil.copy2(str(src), str(dst))
            copied += 1
            logger.info("config_file_installed", file=str(dst))
        else:
            logger.warning("bundled_file_missing", file=filename)

    for filename in env_files:
        src = bundled / "environments" / filename
        dst = environments_dir / filename
        if src.exists():
            shutil.copy2(str(src), str(dst))
            copied += 1
            logger.info("config_file_installed", file=str(dst))

    logger.info("config_initialized", target=str(target), files_copied=copied)

    try:
        os.chmod(str(target), stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)
    except OSError:
        pass
