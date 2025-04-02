#!/bin/bash
#
# Git Branch Cleanup - A tool to safely analyze and delete local git branches
#
# This script detects branches that can be safely deleted, including:
# - Branches with no unique commits
# - Branches that have been properly merged
# - Branches that have been squash-merged
# - Branches with deleted upstream references
# - Stale branches that haven't been modified in a long time

# ===== INITIALIZATION =====

# Define color codes for output (must be defined before first use)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Exit if not in a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo -e "${RED}Error: Not inside a git repository${NC}"
    exit 1
fi

# Default configuration
VERSION="1.0.0"
DRY_RUN=false
DEBUG=false
FORCE=false
HELP=false
STALE_DAYS=90
SHOW_PROGRESS=true
INCLUDE_PATTERN=""
EXCLUDE_PATTERN=""

# ===== FUNCTIONS =====

# Display help information and exit
function show_help {
    echo -e "${GREEN}Git Branch Cleanup v$VERSION${NC}"
    echo -e "---------------------"
    echo -e "A tool to safely clean up local git branches"
    echo -e ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  --dry-run         Show what branches would be deleted without actually deleting them"
    echo -e "  --debug           Show additional debug information during branch analysis"
    echo -e "  --force           Skip confirmation and delete all branches automatically"
    echo -e "  --stale-days=N    Set the threshold for stale branches (default: 90 days)"
    echo -e "  --include=PATTERN Only process branches matching the given pattern"
    echo -e "  --exclude=PATTERN Skip branches matching the given pattern"
    echo -e "  --quiet           Reduce output during branch analysis"
    echo -e "  --help            Show this help message"
    echo -e "\n${BLUE}Examples:${NC}"
    echo -e "  $(basename "$0") --dry-run                  # Show what branches would be deleted"
    echo -e "  $(basename "$0") --include=feature          # Only process feature branches"
    echo -e "  $(basename "$0") --stale-days=30 --force    # Delete all branches older than 30 days"
    exit 0
}

# Clean up temporary files when exiting
cleanup() {
    rm -f "$report_file" "$keep_file"
    echo -e "\n${BLUE}💫 Cleanup complete!${NC}"
    exit 0
}

# Function to delete or simulate deletion based on DRY_RUN flag
delete_branch() {
    local branch=$1
    local reason=$2
    local deleted_count_var=$3
    local failed_count_var=$4

    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}✅ Would delete: ${branch}${NC} $([ -n "$reason" ] && echo "(${reason})")"
        eval "$deleted_count_var=$((${!deleted_count_var}+1))"
    else
        if git branch -D "$branch" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Deleted: ${branch}${NC} $([ -n "$reason" ] && echo "(${reason})")"
            eval "$deleted_count_var=$((${!deleted_count_var}+1))"
        else
            echo -e "${RED}❌ Failed to delete: ${branch}${NC}"
            eval "$failed_count_var=$((${!failed_count_var}+1))"
        fi
    fi
}

# ===== PARSE COMMAND-LINE ARGUMENTS =====

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help)
            HELP=true
            shift
            ;;
        --quiet)
            SHOW_PROGRESS=false
            shift
            ;;
        --stale-days=*)
            STALE_DAYS="${arg#*=}"
            if ! [[ "$STALE_DAYS" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Error: stale days must be a number${NC}"
                exit 1
            fi
            shift
            ;;
        --include=*)
            INCLUDE_PATTERN="${arg#*=}"
            shift
            ;;
        --exclude=*)
            EXCLUDE_PATTERN="${arg#*=}"
            shift
            ;;
    esac
done

# Show help if requested
$HELP && show_help

# ===== REPOSITORY SETUP =====

# Attempt to auto-detect main branch
MAIN_BRANCH=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
MAIN_BRANCH=${MAIN_BRANCH:-main} # Default to 'main' if detection fails

# Initialize reporting files
report_file=$(mktemp)
keep_file=$(mktemp)
total=0

# Set up cleanup on exit
trap cleanup EXIT

# ===== BRANCH ANALYSIS =====

# Fetch latest changes
echo -e "${BLUE}🔄 Syncing with remote...${NC}"
git fetch --all --prune --quiet

# Checkout main branch
echo -e "${BLUE}⏩ Checking out $MAIN_BRANCH branch...${NC}"
git checkout -q $MAIN_BRANCH

# Find candidate branches
echo -e "${BLUE}🔎 Analyzing branches...${NC}"
branch_count=$(git for-each-ref refs/heads/ --format="%(refname:short)" | wc -l)
current=0

# Process all local branches
git for-each-ref refs/heads/ --format='%(refname:short)' | while IFS= read -r branch; do
    current=$((current + 1))

    # Show progress if enabled
    if $SHOW_PROGRESS; then
        percent=$((current * 100 / branch_count))
        bar_length=$(( percent * 20 / 100 ))
        bar_length=$(( bar_length > 0 ? bar_length : 0 ))
        progress_bar=""
        if [ "$bar_length" -gt 0 ]; then
            progress_bar=$(printf "%-${bar_length}s" "=" | tr ' ' "=")
        fi
        progress_bar=$(printf "%-20s" "$progress_bar")
        printf "\r${BLUE}[%-20s] %3d%% ${NC}Analyzing: %-40s" "$progress_bar" "$percent" "$branch"
    fi

    # Skip branch if it doesn't match include pattern
    if [ -n "$INCLUDE_PATTERN" ] && ! [[ "$branch" =~ $INCLUDE_PATTERN ]]; then
        continue
    fi

    # Skip branch if it matches exclude pattern
    if [ -n "$EXCLUDE_PATTERN" ] && [[ "$branch" =~ $EXCLUDE_PATTERN ]]; then
        continue
    fi

    # Skip main branch
    [ "$branch" = "$MAIN_BRANCH" ] && continue

    # DETECTION METHOD 1: Identical branches (no new commits)
    if [ "$(git merge-base $MAIN_BRANCH "$branch")" = "$(git rev-parse "$branch")" ]; then
        if ! git rev-parse --abbrev-ref --symbolic-full-name "$branch"@{upstream} &>/dev/null; then
            echo "$branch|Local branch with no new commits" >> "$report_file"
            continue
        fi
    fi

    # DETECTION METHOD 2: Properly merged branches (standard merge)
    if git branch --merged $MAIN_BRANCH | grep -q "^[\* ] $branch$"; then
        echo "$branch|Merged into $MAIN_BRANCH (regular merge)" >> "$report_file"
        continue
    fi

    # DETECTION METHOD 3: Squash-merged branches
    branch_tip=$(git rev-parse "$branch")
    mergeBase=$(git merge-base $MAIN_BRANCH "$branch")

    # Get the diff between merge-base and branch tip
    diff_output=$(git diff --name-only $mergeBase $branch)

    # Skip empty branches
    if [ -z "$diff_output" ]; then
        echo "$branch|Empty branch (no changes)" >> "$report_file"
        continue
    fi

    # Method 3.1: Tree comparison - most reliable for standard squash merges
    branch_tree=$(git rev-parse "$branch^{tree}")
    virtual_commit=$(git commit-tree $branch_tree -p $mergeBase -m "Virtual commit for squash merge detection")

    if $DEBUG; then
        echo "DEBUG: Branch $branch - Tree hash: $branch_tree, Virtual commit: $virtual_commit"
    fi

    if git merge-base --is-ancestor $virtual_commit $MAIN_BRANCH; then
        echo "$branch|Squash-merged into $MAIN_BRANCH (tree match)" >> "$report_file"
        continue
    fi

    # Method 3.2: Patch ID comparison - reliable for detecting identical changes
    branch_patch_id=$(git diff $mergeBase $branch | git patch-id --stable | cut -d' ' -f1)

    if [ -n "$branch_patch_id" ]; then
        if git log --no-merges -p $mergeBase..$MAIN_BRANCH | git patch-id --stable | cut -d' ' -f1 | grep -q "$branch_patch_id"; then
            echo "$branch|Squash-merged into $MAIN_BRANCH (patch match)" >> "$report_file"
            continue
        fi
    fi

    # Method 3.3: Content match - checks if all changes from branch exist in main
    changes_not_in_main=false
    while read -r file; do
        if [ -n "$file" ]; then
            file_diff=$(git diff --unified=0 $mergeBase $branch -- "$file")
            # Use fixed string matching to avoid regex issues
            if ! git log $mergeBase..$MAIN_BRANCH -p --unified=0 -- "$file" | grep -F -q "${file_diff#*@@}"; then
                changes_not_in_main=true
                break
            fi
        fi
    done <<< "$diff_output"

    if [ "$changes_not_in_main" = false ] && [ -n "$diff_output" ]; then
        echo "$branch|Squash-merged into $MAIN_BRANCH (content match)" >> "$report_file"
        continue
    fi

    # Method 3.4: Commit message reference - catches UI-based squash merges
    branch_name_pattern=$(echo "$branch" | sed 's/[\/\.]/\\&/g')
    if git log $mergeBase..$MAIN_BRANCH --grep="$branch_name_pattern" --format="%H" | grep -q .; then
        echo "$branch|Squash-merged into $MAIN_BRANCH (commit message reference)" >> "$report_file"
        continue
    fi

    # DETECTION METHOD 4: Deleted upstream branches
    if git branch -vv | grep -q "^[* ] $branch.*: gone\\]"; then
        echo "$branch|Upstream branch deleted" >> "$report_file"
        continue
    fi

    # DETECTION METHOD 5: Stale branches
    last_commit_date=$(git log -1 --format=%at "$branch")
    current_time=$(date +%s)
    days_old=$(( (current_time - last_commit_date) / 86400 ))
    if [ $days_old -gt $STALE_DAYS ]; then
        echo "$branch|Stale branch ($days_old days old)" >> "$report_file"
        continue
    fi

    # Branch will be kept
    echo "$branch" >> "$keep_file"
done

# Clear the progress line
if $SHOW_PROGRESS; then
    printf "\r%-80s\r" " "
fi

# ===== REPORT GENERATION =====

# Process report
sort -u "$report_file" > "${report_file}.tmp"
mv "${report_file}.tmp" "$report_file"
total=$(wc -l < "$report_file" | tr -d ' ')

# Display report
echo
echo -e "${GREEN}🚀 Branch Cleanup Report${NC}"
echo -e "${GREEN}-----------------------${NC}"
echo -e "${YELLOW}Branches to delete:${NC}"
printf "${YELLOW}%-4s %-40s %-40s${NC}\n" "#" "Branch Name" "Reason for Deletion"
echo "--------------------------------------------------------------------------------"

index=1
declare -A branch_map
while IFS='|' read -r branch reason; do
    printf "${BLUE}%-4s${NC} %-40s ${YELLOW}%-40s${NC}\n" "$index" "$branch" "$reason"
    branch_map[$index]="$branch"
    ((index++))
done < "$report_file"

echo -e "\n${GREEN}Total branches to delete: $total${NC}"

# Display branches to keep
echo -e "\n${BLUE}Branches to keep:${NC}"
sort -u "$keep_file" | while IFS= read -r branch; do
    echo -e "${GREEN}✓ ${branch}${NC}"
done

# ===== INTERACTIVE DELETION =====

if [ "$DRY_RUN" = true ]; then
    echo -e "\n🏜️ ${YELLOW}Dry run, no changes will be made${NC}"
fi

if [ $total -gt 0 ]; then
    # FORCE MODE - Skip interactive prompt
    if [ "$FORCE" = true ]; then
        echo -e "\n${RED}$([[ "$DRY_RUN" = true ]] && echo "Would delete" || echo "Deleting") all branches...${NC}"
        deleted_count=0
        failed_count=0
        while IFS='|' read -r branch reason; do
            delete_branch "$branch" "$reason" deleted_count failed_count
        done < "$report_file"

        # Add summary after deletion
        echo -e "\n${GREEN}🎉 Branch cleanup $([[ "$DRY_RUN" = true ]] && echo "simulated" || echo "completed")!${NC}"
        if [ "$DRY_RUN" = true ]; then
            echo -e "${GREEN}Would delete $deleted_count branches${NC}"
        else
            echo -e "${GREEN}Successfully deleted $deleted_count branches, $failed_count failed${NC}"
        fi
        exit 0
    fi

    # SAFETY CHECK for unpushed commits (only if we're actually deleting)
    if [ "$DRY_RUN" = false ]; then
        unsafe_branches=0
        while IFS='|' read -r branch reason; do
            # Skip branches without tracking relationships
            if ! git rev-parse --abbrev-ref --symbolic-full-name "$branch"@{upstream} &>/dev/null; then
                continue
            fi

            if [ -n "$(git log @{push}..HEAD --format=oneline --abbrev-commit "$branch" 2>/dev/null)" ]; then
                echo -e "${RED}⚠️ WARNING: $branch has unpushed commits and won't be deleted${NC}"
                unsafe_branches=$((unsafe_branches+1))
                # Remove unsafe branch from report
                sed -i "/^$branch|/d" "$report_file"
            fi
        done < "$report_file"

        # Recalculate total after safety check
        total=$(wc -l < "$report_file" | tr -d ' ')
    fi

    # INTERACTIVE MODE - Choose branches to delete
    action_text=$([[ "$DRY_RUN" = true ]] && echo "simulate deletion of" || echo "delete")
    echo -e "\n${YELLOW}❓ Choose action:${NC}"
    echo -e "${GREEN}a${NC} - ${action_text^} all branches"
    echo -e "${GREEN}1-$total${NC} - Select specific branches (space-separated)"
    echo -e "${RED}c${NC} - Cancel operation"

    while true; do
        read -p "Your choice: " choice
        case "$choice" in
            a|A)
                echo -e "\n${RED}$([[ "$DRY_RUN" = true ]] && echo "🔍 Simulating deletion" || echo "🗑️ Deleting") all branches...${NC}"
                deleted_count=0
                failed_count=0
                while IFS='|' read -r branch reason; do
                    delete_branch "$branch" "$reason" deleted_count failed_count
                done < "$report_file"

                # Add summary after deletion
                echo -e "\n${GREEN}🎉 Branch cleanup $([[ "$DRY_RUN" = true ]] && echo "simulation" || echo "completed")!${NC}"
                if [ "$DRY_RUN" = true ]; then
                    echo -e "${GREEN}Would delete $deleted_count branches${NC}"
                else
                    echo -e "${GREEN}Successfully deleted $deleted_count branches, $failed_count failed${NC}"
                fi
                break
                ;;
            c|C)
                echo -e "${RED}🚫 Operation cancelled${NC}"
                exit 0
                ;;
            *)
                declare -a branches_to_delete=()
                valid_input=true
                for input in $choice; do
                    if [[ $input =~ ^[0-9]+$ ]] && [ $input -ge 1 ] && [ $input -le $total ]; then
                        branches_to_delete+=("${branch_map[$input]}")
                    else
                        echo -e "${RED}⚠️ Invalid selection: $input${NC}"
                        valid_input=false
                        break
                    fi
                done

                if $valid_input; then
                    [ ${#branches_to_delete[@]} -eq 0 ] && break
                    echo -e "\n${RED}$([[ "$DRY_RUN" = true ]] && echo "🔍 Simulating deletion of" || echo "🗑️ Deleting") selected branches...${NC}"
                    deleted_count=0
                    failed_count=0
                    for branch in "${branches_to_delete[@]}"; do
                        # Find the reason from the report file
                        reason=$(grep "^$branch|" "$report_file" | cut -d'|' -f2)
                        delete_branch "$branch" "$reason" deleted_count failed_count
                    done

                    # Add summary after deletion
                    echo -e "\n${GREEN}🎉 Branch cleanup $([[ "$DRY_RUN" = true ]] && echo "simulation" || echo "completed")!${NC}"
                    if [ "$DRY_RUN" = true ]; then
                        echo -e "${GREEN}Would delete $deleted_count branches${NC}"
                    else
                        echo -e "${GREEN}Successfully deleted $deleted_count branches, $failed_count failed${NC}"
                    fi
                    break
                fi
                ;;
        esac
    done
else
    echo -e "\n${GREEN}🎉 No branches need deletion!${NC}"
fi
