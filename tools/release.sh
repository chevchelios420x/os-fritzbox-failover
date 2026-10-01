#!/bin/sh
#
# Creates a new release: sets PLUGIN_VERSION in the Makefile, commits it,
# tags vX.Y and pushes branch and tag. The tag triggers
# .github/workflows/release.yml, which builds the .pkg and attaches it to
# the GitHub release.
#
# usage: tools/release.sh <version>      e.g. tools/release.sh 1.1
#

set -eu

VERSION="${1:-}"
BRANCH="main"
TAG="v${VERSION}"

die() { echo "error: $*" >&2; exit 1; }

echo "${VERSION}" | grep -Eq '^[0-9]+(\.[0-9]+)+$' || die "usage: $0 <version>, e.g. 1.1"

cd "$(dirname "$0")/.."

[ "$(git rev-parse --abbrev-ref HEAD)" = "${BRANCH}" ] || die "not on branch ${BRANCH}"
[ -z "$(git status --porcelain)" ] || die "working tree not clean, commit or stash first"

git fetch -q origin "${BRANCH}" --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/${BRANCH}")" ] || die "local ${BRANCH} differs from origin/${BRANCH}, pull or push first"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "tag ${TAG} already exists"

for f in src/opnsense/scripts/OPNsense/FritzFailover/*.sh src/etc/rc.d/fritzfailover; do
	sh -n "$f" || die "syntax error in $f"
done
if command -v php >/dev/null 2>&1; then
	find src -name '*.php' -o -name '*.inc' | while read -r f; do
		php -l "$f" >/dev/null || die "syntax error in $f"
	done
fi

CURRENT=$(sed -n 's/^PLUGIN_VERSION=[[:space:]]*//p' Makefile)
if [ "${CURRENT}" != "${VERSION}" ]; then
	sed -i.bak "s/^PLUGIN_VERSION=.*/PLUGIN_VERSION=		${VERSION}/" Makefile && rm -f Makefile.bak
	git add Makefile
	git commit -q -m "Release ${VERSION}"
	echo ">>> Makefile updated: ${CURRENT} -> ${VERSION}"
fi

git tag -a "${TAG}" -m "os-fritzbox-failover ${VERSION}"
git push -q origin "${BRANCH}"
git push -q origin "${TAG}"

REPO=$(git remote get-url origin | sed -E 's#(\.git)?$##; s#^.*github\.com[:/]##; s#^.*/git/##')
echo ">>> Tag ${TAG} pushed."
echo ">>> Build:   https://github.com/${REPO}/actions"
echo ">>> Release: https://github.com/${REPO}/releases/tag/${TAG}"
