#!/bin/bash

test_description='config-managed multihooks, including git-hook command'

. ./test-lib.sh

ROOT=
if test_have_prereq MINGW
then
	# In Git for Windows, Unix-like paths work only in shell scripts;
	# `git.exe`, however, will prefix them with the pseudo root directory
	# (of the Unix shell). Let's accommodate for that.
	ROOT="$(cd / && pwd)"
fi

setup_hooks () {
	test_config hook.pre-commit.command "/path/ghi" --add
	test_config_global hook.pre-commit.command "/path/def" --add
}

setup_hookcmd () {
	test_config hook.pre-commit.command "abc" --add
	test_config_global hookcmd.abc.command "/path/abc" --add
}

setup_hookdir () {
	mkdir .git/hooks
	write_script .git/hooks/pre-commit <<-EOF
	echo \"Legacy Hook\"
	EOF
	test_when_finished rm -rf .git/hooks
}

test_expect_success 'git hook rejects commands without a mode' '
	test_must_fail git hook pre-commit
'


test_expect_success 'git hook rejects commands without a hookname' '
	test_must_fail git hook list
'

test_expect_success 'git hook runs outside of a repo' '
	setup_hooks &&

	cat >expected <<-EOF &&
	global: $ROOT/path/def
	EOF

	nongit git config --list --global &&

	nongit git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list orders by config order' '
	setup_hooks &&

	cat >expected <<-EOF &&
	global: $ROOT/path/def
	local: $ROOT/path/ghi
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list dereferences a hookcmd' '
	setup_hooks &&
	setup_hookcmd &&

	cat >expected <<-EOF &&
	global: $ROOT/path/def
	local: $ROOT/path/ghi
	local: $ROOT/path/abc
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list reorders on duplicate commands' '
	setup_hooks &&

	test_config hook.pre-commit.command "/path/def" --add &&

	cat >expected <<-EOF &&
	local: $ROOT/path/ghi
	local: $ROOT/path/def
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list shows hooks from the hookdir' '
	setup_hookdir &&

	cat >expected <<-EOF &&
	hookdir: $(pwd)/.git/hooks/pre-commit
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'hook.runHookDir = no is respected by list' '
	setup_hookdir &&

	test_config hook.runHookDir "no" &&

	cat >expected <<-EOF &&
	hookdir: $(pwd)/.git/hooks/pre-commit (will not run)
	EOF

	git hook list pre-commit >actual &&
	# the hookdir annotation is translated
	test_cmp expected actual &&

	git hook run pre-commit 2>actual &&
	test_must_be_empty actual
'

test_expect_success 'hook.runHookDir = error is respected by list' '
	setup_hookdir &&

	test_config hook.runHookDir "error" &&

	cat >expected <<-EOF &&
	hookdir: $(pwd)/.git/hooks/pre-commit (will error and not run)
	EOF

	git hook list pre-commit >actual &&
	# the hookdir annotation is translated
	test_cmp expected actual &&

	cat >expected <<-EOF &&
	Skipping legacy hook at '\''$(pwd)/.git/hooks/pre-commit'\''
	EOF

	git hook run pre-commit 2>actual &&
	test_cmp expected actual
'

test_expect_success 'hook.runHookDir = warn is respected by list' '
	setup_hookdir &&

	test_config hook.runHookDir "warn" &&

	cat >expected <<-EOF &&
	hookdir: $(pwd)/.git/hooks/pre-commit (will warn but run)
	EOF

	git hook list pre-commit >actual &&
	# the hookdir annotation is translated
	test_cmp expected actual &&

	cat >expected <<-EOF &&
	Running legacy hook at '\''$(pwd)/.git/hooks/pre-commit'\''
	"Legacy Hook"
	EOF

	git hook run pre-commit 2>actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list removes skipped hookcmd' '
	setup_hookcmd &&
	test_config hookcmd.abc.skip "true" --add &&

	cat >expected <<-EOF &&
	no commands configured for hook '\''pre-commit'\''
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list ignores skip referring to unused hookcmd' '
	test_config hookcmd.abc.command "/path/abc" --add &&
	test_config hookcmd.abc.skip "true" --add &&

	cat >expected <<-EOF &&
	no commands configured for hook '\''pre-commit'\''
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'git hook list removes skipped inlined hook' '
	setup_hooks &&
	test_config hookcmd."$ROOT/path/ghi".skip "true" --add &&

	cat >expected <<-EOF &&
	global: $ROOT/path/def
	EOF

	git hook list pre-commit >actual &&
	test_cmp expected actual
'

test_expect_success 'hook.runHookDir = interactive is respected by list and run' '
	setup_hookdir &&

	test_config hook.runHookDir "interactive" &&

	cat >expected <<-EOF &&
	hookdir: $(pwd)/.git/hooks/pre-commit (will prompt)
	EOF

	git hook list pre-commit >actual &&
	# the hookdir annotation is translated
	test_cmp expected actual &&

	test_write_lines n | git hook run pre-commit 2>actual &&
	! grep "Legacy Hook" actual &&

	test_write_lines y | git hook run pre-commit 2>actual &&
	grep "Legacy Hook" actual
'

test_expect_success 'inline hook definitions execute oneliners' '
	test_config hook.pre-commit.command "echo \"Hello World\"" &&

	echo "Hello World" >expected &&

	# hooks are run with stdout_to_stderr = 1
	git hook run pre-commit 2>actual &&
	test_cmp expected actual
'

test_expect_success 'inline hook definitions resolve paths' '
	write_script sample-hook.sh <<-EOF &&
	echo \"Sample Hook\"
	EOF

	test_when_finished "rm sample-hook.sh" &&

	test_config hook.pre-commit.command "\"$(pwd)/sample-hook.sh\"" &&

	echo \"Sample Hook\" >expected &&

	# hooks are run with stdout_to_stderr = 1
	git hook run pre-commit 2>actual &&
	test_cmp expected actual
'

test_expect_success 'git hook run can pass args and env vars' '
	write_script sample-hook.sh <<-\EOF &&
	echo $1
	echo $2
	echo $TEST_ENV_1
	echo $TEST_ENV_2
	EOF

	test_config hook.pre-commit.command "\"$(pwd)/sample-hook.sh\"" &&

	cat >expected <<-EOF &&
	arg1
	arg2
	env1
	env2
	EOF

	git hook run --arg arg1 \
		--env TEST_ENV_1=env1 \
		-a arg2 \
		-e TEST_ENV_2=env2 \
		pre-commit 2>actual &&

	test_cmp expected actual
'

test_expect_success 'hookdir hook included in git hook run' '
	setup_hookdir &&

	echo \"Legacy Hook\" >expected &&

	# hooks are run with stdout_to_stderr = 1
	git hook run pre-commit 2>actual &&
	test_cmp expected actual
'

test_expect_success 'out-of-repo runs excluded' '
	setup_hooks &&

	nongit test_must_fail git hook run pre-commit
'

test_expect_success 'hook.runHookDir is tolerant to unknown values' '
	setup_hookdir &&

	test_config hook.runHookDir "junk" &&

	cat >expected <<-EOF &&
	hookdir: $(pwd)/.git/hooks/pre-commit
	EOF

	git hook list pre-commit >actual &&
	# the hookdir annotation is translated
	test_cmp expected actual
'

test_done
