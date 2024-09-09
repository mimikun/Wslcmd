#!/bin/bash

TODAY=$(date "+%Y.%m.%d")
RESULT_FILE="CHANGELOG.md"
LATEST_GIT_TAG=$(git tag | head -n 1)
GIT_LOG=$(git log "$LATEST_GIT_TAG..HEAD" --pretty=format:"%B")
HOSTNAME=$(hostname)

home() {
    echo "## [v$TODAY]"
    echo ""
    echo "$GIT_LOG" |
        # Remove renovate commit
        sed -e 's/.*chore(deps): update dependency.*//g' |
        # Remove blank line
        sed -e '/^$/d' |
        # Make list
        sed -e 's/^/- /g'
    echo ""
    echo "### Added"
    echo ""
    echo "None"
    echo ""
    echo "### Changed"
    echo ""
    echo "None"
    echo ""
    echo "### Removed"
    echo ""
    echo "None"
    echo ""
    echo "### Fixed"
    echo ""
    echo "None"
    echo ""
}

work() {
    echo "## run"
    echo ""
    echo '```bash'
    echo 'git commit -m "WIP:--------------------------------------------------------------------------" --allow-empty --no-verify'
    echo "$GIT_LOG" |
        # Remove blank line
        sed -e '/^$/d' |
        # Remove STARTUPTIME.md commit msg
        sed -e 's/.*STARTUPTIME.md.*//g' |
        # Remove DROP commit msg
        sed -e 's/.*DROP.*//g' |
        # Remove renovate commit
        sed -e 's/.*chore(deps): update dependency.*//g' |
        # Remove blank line
        sed -e '/^$/d' |
        sed -e 's/^/git commit -m "WIP:/g' |
        sed -e 's/$/" --allow-empty --no-verify/g'
    echo 'git commit -m "WIP:--------------------------------------------------------------------------" --allow-empty --no-verify'
    echo '```'
}

if [[ "$HOSTNAME" = "TanakaPC" ]]; then
    work >>$RESULT_FILE
    git add "$RESULT_FILE"
    git commit -m "changelog" --no-verify
else
    home >>$RESULT_FILE
fi
