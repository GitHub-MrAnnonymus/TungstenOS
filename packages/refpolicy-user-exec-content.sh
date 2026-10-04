#!/usr/bin/env bash
# Adds a user_exec_content tunable (default off, as in Fedora's policy) around
# the rules that let confined users execute files in their home and /tmp.
# Run from the refpolicy source root.
set -euo pipefail
if='policy/modules/system/userdomain.if'
te='policy/modules/system/userdomain.te'
grep -q 'userdom_exec_user_home_content_files($1_t)' "$if"
grep -q 'gen_tunable(user_exec_noexattrfile, false)' "$te"
python3 - "$if" "$te" <<'PY'
import sys
iff, te = sys.argv[1], sys.argv[2]
s = open(iff).read()
old = "\tuserdom_exec_user_tmp_files($1_t)\n\tuserdom_exec_user_home_content_files($1_t)\n"
# Conditionals cannot nest, and userdom_exec_user_home_content_files contains
# tunable_policy blocks, so the plain rules are inlined instead.
new = ("\tgen_require(`\n"
       "\t\ttype user_home_dir_t, user_home_t, user_tmp_t;\n"
       "\t')\n"
       "\tfiles_search_home($1_t)\n"
       "\tfiles_search_tmp($1_t)\n"
       "\tuserdom_search_user_runtime($1_t)\n"
       "\ttunable_policy(`user_exec_content',`\n"
       "\t\texec_files_pattern($1_t, { user_home_dir_t user_home_t }, user_home_t)\n"
       "\t\texec_files_pattern($1_t, user_tmp_t, user_tmp_t)\n"
       "\t')\n")
assert s.count(old) == 1, "userdomain.if: expected exactly one match"
open(iff, "w").write(s.replace(old, new))
t = open(te).read()
anchor = "gen_tunable(user_exec_noexattrfile, false)\n"
add = ("\n## <desc>\n## <p>\n## Allow users to execute files in their home directory and /tmp.\n"
       "## </p>\n## </desc>\ngen_tunable(user_exec_content, false)\n")
open(te, "w").write(t.replace(anchor, anchor + add, 1))
PY
