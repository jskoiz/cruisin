#!/usr/bin/env python3
"""Build the local Voice Hack Night submission artifact pack."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = PROJECT_ROOT / ".derivedData" / "demo-artifacts"
DEFAULT_OUTPUT = PROJECT_ROOT / "dist" / "voice-hack-night"
DEFAULT_ANSWERS_SOURCE = PROJECT_ROOT / "README.md"
APPLICATION_HEADING = "## Application Materials"

VIDEO_EXTENSIONS = {".m4v", ".mov", ".mp4"}
SCREENSHOT_EXTENSIONS = {".heic", ".jpeg", ".jpg", ".png"}
IGNORED_PATHS_TO_VERIFY = (
    ".derivedData/demo-artifacts",
    "dist/voice-hack-night",
    ".env",
    ".env.local",
    "Secrets.xcconfig",
    "Cruisin/Secrets.plist",
)


@dataclass(frozen=True)
class SourceArtifact:
    kind: str
    path: Path


@dataclass(frozen=True)
class PackagedFile:
    kind: str
    source: Path
    destination: Path
    bytes: int
    sha256: str

    def manifest_record(self, output: Path) -> dict[str, object]:
        return {
            "kind": self.kind,
            "path": self.destination.relative_to(output).as_posix(),
            "source": safe_relative_path(self.source),
            "bytes": self.bytes,
            "sha256": self.sha256,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Copy local Voice Hack Night videos/screenshots from "
            ".derivedData/demo-artifacts into dist/voice-hack-night with "
            "application answers, a manifest, and SHA-256 checksums."
        )
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE,
        help="Directory containing local demo videos/screenshots.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Directory to rebuild with the submission pack.",
    )
    parser.add_argument(
        "--answers-source",
        type=Path,
        default=DEFAULT_ANSWERS_SOURCE,
        help="Markdown file containing the Application Materials section.",
    )
    parser.add_argument(
        "--skip-git-ignore-check",
        action="store_true",
        help="Do not verify that local media and secret paths are git-ignored.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source = args.source.expanduser().resolve()
    output = args.output.expanduser().resolve()
    answers_source = args.answers_source.expanduser().resolve()

    try:
        if not args.skip_git_ignore_check:
            verify_git_ignores()
        validate_paths(source, output, answers_source)
        media_artifacts, skipped = collect_media(source)
        require_media(media_artifacts)

        rebuild_output_directory(output)
        packaged_media = copy_media(media_artifacts, output)

        application_answers = write_application_answers(answers_source, output)
        application_record = file_record(
            "application-answer",
            answers_source,
            application_answers,
        )

        manifest_path = output / "manifest.json"
        write_manifest(
            manifest_path,
            source,
            output,
            answers_source,
            packaged_media,
            application_record,
            skipped,
            git_ignore_verified=not args.skip_git_ignore_check,
        )
        manifest_record = file_record("manifest", manifest_path, manifest_path)

        checksum_records = [application_record, *packaged_media, manifest_record]
        write_checksums(output / "CHECKSUMS.txt", output, checksum_records)
    except PackagerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    videos = sum(1 for item in packaged_media if item.kind == "video")
    screenshots = sum(1 for item in packaged_media if item.kind == "screenshot")
    print(f"Created {safe_relative_path(output)}")
    print(f"Copied {videos} video(s) and {screenshots} screenshot(s)")
    print("Wrote application-answers.md, manifest.json, and CHECKSUMS.txt")
    if skipped:
        print(f"Skipped {len(skipped)} non-media file(s)")
    return 0


class PackagerError(RuntimeError):
    """Expected packaging failure with a user-actionable message."""


def verify_git_ignores() -> None:
    missing = []
    for path in IGNORED_PATHS_TO_VERIFY:
        result = subprocess.run(
            ["git", "check-ignore", "--quiet", "--no-index", path],
            cwd=PROJECT_ROOT,
            check=False,
        )
        if result.returncode != 0:
            missing.append(path)

    if missing:
        formatted = ", ".join(missing)
        raise PackagerError(
            "these local media/secret paths are not protected by .gitignore: "
            f"{formatted}"
        )


def validate_paths(source: Path, output: Path, answers_source: Path) -> None:
    if not source.is_dir():
        raise PackagerError(
            f"source artifact directory is missing: {safe_relative_path(source)}"
        )
    if not answers_source.is_file():
        raise PackagerError(
            f"application answer source is missing: {safe_relative_path(answers_source)}"
        )
    if output in {PROJECT_ROOT, PROJECT_ROOT.parent, Path.home(), Path("/")}:
        raise PackagerError(f"refusing to clean unsafe output path: {output}")
    if source == output or source in output.parents:
        raise PackagerError("output directory must not be inside the source directory")
    if output == source.parent:
        raise PackagerError("output directory must not be the source parent")


def rebuild_output_directory(output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    (output / "videos").mkdir(parents=True, exist_ok=True)
    (output / "screenshots").mkdir(parents=True, exist_ok=True)


def collect_media(source: Path) -> tuple[list[SourceArtifact], list[str]]:
    artifacts: list[SourceArtifact] = []
    skipped: list[str] = []

    for path in sorted(source.rglob("*"), key=lambda item: item.relative_to(source).as_posix()):
        if not path.is_file():
            continue

        media_kind = classify_media(path)
        if media_kind is None:
            skipped.append(path.relative_to(source).as_posix())
            continue

        artifacts.append(SourceArtifact(kind=media_kind, path=path))

    return artifacts, skipped


def copy_media(artifacts: list[SourceArtifact], output: Path) -> list[PackagedFile]:
    packaged: list[PackagedFile] = []
    destinations: set[Path] = set()

    for artifact in artifacts:
        subdir = "videos" if artifact.kind == "video" else "screenshots"
        destination = output / subdir / artifact.path.name
        if destination in destinations:
            raise PackagerError(
                "duplicate artifact filename would collide in the pack: "
                f"{artifact.path.name}"
            )
        destinations.add(destination)

        shutil.copy2(artifact.path, destination)
        packaged.append(file_record(artifact.kind, artifact.path, destination))

    return packaged


def classify_media(path: Path) -> str | None:
    extension = path.suffix.lower()
    if extension in VIDEO_EXTENSIONS:
        return "video"
    if extension in SCREENSHOT_EXTENSIONS:
        return "screenshot"
    return None


def require_media(media_artifacts: list[SourceArtifact]) -> None:
    videos = [item for item in media_artifacts if item.kind == "video"]
    screenshots = [item for item in media_artifacts if item.kind == "screenshot"]
    if not videos:
        raise PackagerError("no demo video files found in the source directory")
    if not screenshots:
        raise PackagerError("no screenshot files found in the source directory")


def write_application_answers(answers_source: Path, output: Path) -> Path:
    section = extract_markdown_section(answers_source, APPLICATION_HEADING)
    destination = output / "application-answers.md"
    destination.write_text(
        "\n".join(
            [
                "# Cruisin Voice Hack Night Application Answers",
                "",
                f"Source: `{safe_relative_path(answers_source)}` "
                f"`{APPLICATION_HEADING}` section.",
                "",
                section,
                "",
            ]
        ),
        encoding="utf-8",
    )
    return destination


def extract_markdown_section(path: Path, heading: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    start = next((index for index, line in enumerate(lines) if line.strip() == heading), None)
    if start is None:
        raise PackagerError(f"could not find {heading!r} in {safe_relative_path(path)}")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.startswith("## ") and line.strip() != heading:
            end = index
            break

    section = "\n".join(lines[start + 1 : end]).strip()
    if not section:
        raise PackagerError(f"{heading!r} is empty in {safe_relative_path(path)}")
    return section


def write_manifest(
    manifest_path: Path,
    source: Path,
    output: Path,
    answers_source: Path,
    packaged_media: list[PackagedFile],
    application_record: PackagedFile,
    skipped: list[str],
    git_ignore_verified: bool,
) -> None:
    files = [application_record, *packaged_media]
    manifest = {
        "packName": "cruisin-voice-hack-night",
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "sourceArtifacts": safe_relative_path(source),
        "outputDirectory": safe_relative_path(output),
        "applicationAnswersSource": safe_relative_path(answers_source),
        "gitIgnoreVerified": git_ignore_verified,
        "gitIgnoreProtectedPaths": list(IGNORED_PATHS_TO_VERIFY),
        "counts": {
            "videos": sum(1 for item in packaged_media if item.kind == "video"),
            "screenshots": sum(1 for item in packaged_media if item.kind == "screenshot"),
            "skippedNonMedia": len(skipped),
        },
        "files": [item.manifest_record(output) for item in files],
        "skippedNonMedia": skipped,
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_checksums(
    checksums_path: Path,
    output: Path,
    records: list[PackagedFile],
) -> None:
    lines = [
        "# SHA-256 checksums for the Cruisin Voice Hack Night artifact pack",
        "# CHECKSUMS.txt is not self-referential and is intentionally excluded.",
    ]
    for record in records:
        relative_path = record.destination.relative_to(output).as_posix()
        lines.append(f"{record.sha256}  {relative_path}")
    checksums_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def file_record(kind: str, source: Path, destination: Path) -> PackagedFile:
    return PackagedFile(
        kind=kind,
        source=source,
        destination=destination,
        bytes=destination.stat().st_size,
        sha256=sha256(destination),
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative_path(path: Path) -> str:
    resolved = path.expanduser().resolve()
    try:
        return resolved.relative_to(PROJECT_ROOT).as_posix()
    except ValueError:
        return str(resolved)


if __name__ == "__main__":
    raise SystemExit(main())
