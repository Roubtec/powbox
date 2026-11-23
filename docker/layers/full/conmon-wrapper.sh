#!/bin/sh
# conmon wrapper: run the real conmon from the container's persist directory
# rather than from whatever directory `podman run` was started in.
#
# Why this exists
# ---------------
# Podman starts conmon in its own working directory, and conmon 2.x creates an
# empty `oom` marker relative to that directory (besides the copy in
# --persist-dir that Podman reads for State.OOMKilled) whenever it finds a
# nonzero counter in its cgroup's memory.events. Rootless Podman on cgroupfs
# cannot create cgroups here, so every nested container shares the agent
# container's own cgroup, and any earlier OOM kill in the agent container (a
# parallel build, say) leaves that counter nonzero until the container is
# recreated. From then on every nested container that exits or is stopped,
# even an idle one, drops an `oom` file into the checkout it was started from.
#
# Changing directory to the persist directory makes the marker the very file
# Podman already writes there, so nothing appears anywhere else. Every path
# Podman passes conmon is absolute, so conmon's directory affects nothing but
# that marker. Podman's own directory, which relative `-v ./x:/y` paths,
# `--env-file` and compose file discovery resolve against, is not touched,
# because this runs only once Podman has resolved all of them.
#
# Installed off PATH and selected by conmon_path in the engine drop-in
# (containers.conf); Podman falls back to the conmon on PATH if this is absent.

dir=
prev=
for arg in "$@"; do
	case $prev in
	--persist-dir)
		dir=$arg
		break
		;;
	esac
	case $arg in
	--persist-dir=*)
		dir=${arg#--persist-dir=}
		break
		;;
	esac
	prev=$arg
done

# Without --persist-dir (`conmon --version`, or a future Podman that stops
# passing it) the runtime dir still keeps a marker out of the caller's checkout.
cd "${dir:-${XDG_RUNTIME_DIR:-/tmp}}" 2>/dev/null || cd /

exec /usr/bin/conmon "$@"
