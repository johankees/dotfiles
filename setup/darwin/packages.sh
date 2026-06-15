#! /usr/bin/env sh

set -eu

SCRIPT_DIR=$(dirname "$(readlink -f -- "$0")")
SETUP_DIR=$(realpath "${SCRIPT_DIR}/../")

# shellcheck source=./../printing.sh
. "${SETUP_DIR}/printing.sh"

info "setting up homebrew..."
brew_cmd=$(command -v brew 2>&1)

if [ -z "${brew_cmd:-}" ]; then
	brew_cmd=/opt/homebrew/bin/brew
fi

if [ ! -x "${brew_cmd:-}" ]; then
	warn "brew could not be found; please ensure homebrew is installed"
	return 0
fi

eval "$(${brew_cmd} shellenv)"

HOMEBREW_BUNDLE_FILE_GLOBAL="${XDG_DATA_HOME:-$HOME/.local/share}/homebrew/Brewfile"
export HOMEBREW_BUNDLE_FILE_GLOBAL

HOMEBREW_BUNDLE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/homebrew"

if [ ! -r "${HOMEBREW_BUNDLE_FILE_GLOBAL}" ]; then
	# allow user to pick an existing brewfile, or type a new name to dump current brews into
	selection=$(find "${HOMEBREW_BUNDLE_DIR}/" -mindepth 1 -maxdepth 1 -type f -name 'Brewfile.*' -print |
		awk -F/ '{ name=$NF; sub(/^Brewfile\./, "", name); print name "\t" $0 }' |
		fzf --header='Pick a brew bundle or type a new name' \
			--delimiter='\t' \
			--with-nth=1 \
			--preview='cat {2}' \
			--print-query || true)

	query=$(printf '%s\n' "${selection}" | sed -n '1p')
	chosen=$(printf '%s\n' "${selection}" | sed -n '2p' | cut -f2)

	if [ -n "${chosen:-}" ]; then
		brewfile="${chosen}"
	elif [ -n "${query:-}" ]; then
		brewfile="${HOMEBREW_BUNDLE_DIR}/Brewfile.${query}"
		brew bundle dump --brews --casks --mas --force --file="${brewfile}"
	else
		brewfile=""
	fi

	if [ -n "${brewfile:-}" ]; then
		mkdir -p "$(dirname "${HOMEBREW_BUNDLE_FILE_GLOBAL}")"
		ln -Ffs "${brewfile}" "${HOMEBREW_BUNDLE_FILE_GLOBAL}"
	fi
fi

requirements_file="${SCRIPT_DIR}/Brewfile.requirements"
if [ -r "${HOMEBREW_BUNDLE_FILE_GLOBAL}" ] && [ -r "${requirements_file}" ]; then
	info "merging required packages into brewfile..."
	target_brewfile=$(readlink -f -- "${HOMEBREW_BUNDLE_FILE_GLOBAL}")
	merged=$(mktemp)
	awk '
		function pkg_name(line) {
			if (match(line, /"[^"]*"/)) {
				return substr(line, RSTART + 1, RLENGTH - 2)
			}
			return ""
		}
		BEGIN {
			req_header = "# required packages -- do not edit"
			prof_header = "# profile packages"
			print req_header
			print ""
		}
		NR == FNR {
			name = pkg_name($0)
			if (name != "") {
				req[name] = 1
			}
			print
			next
		}
		FNR == 1 {
			print ""
			print prof_header
			print ""
			skip_next_blank = 1
		}
		{
			if ($0 == req_header || $0 == prof_header) {
				pending_blank = 0
				skip_next_blank = 1
				next
			}
			if ($0 == "") {
				if (skip_next_blank) {
					skip_next_blank = 0
					next
				}
				pending_blank++
				next
			}
			skip_next_blank = 0
			name = pkg_name($0)
			if (name != "" && name in req) {
				next
			}
			for (i = 0; i < pending_blank; i++) {
				print ""
			}
			pending_blank = 0
			print
		}
	' "${requirements_file}" "${target_brewfile}" > "${merged}"
	cat "${merged}" > "${target_brewfile}"
	rm -f "${merged}"
fi

required_trust_file="${SCRIPT_DIR}/homebrew/trust.json"
primary_trust_file="${HOMEBREW_BUNDLE_DIR}/trust.json"

# ── step 1: confirm required-trust entries ────────────────────────────────────
# The required trust.json ships with this repo; show its non-official entries
# so the user can review them before any install begins.
if [ -r "${required_trust_file}" ]; then
	trusted_entries=$(grep -oE '"[^"]*/[^"]*"' "${required_trust_file}" | tr -d '"' || true)
	if [ -n "${trusted_entries:-}" ]; then
		warn "the required trust.json trusts these non-official taps/formulae/casks; their code loads during install:"
		printf '%s\n' "${trusted_entries}" | sed 's/^/      - /'

		if [ -r /dev/tty ]; then
			warn "review the entries above; proceed with install? [y/N]"
			read -r reply < /dev/tty || reply=""
			case "${reply}" in
			[Yy] | [Yy][Ee][Ss]) ;;
			*)
				error "aborted: required trust not confirmed"
				exit 1
				;;
			esac
		else
			warn "no tty available; skipping required-trust confirmation"
		fi
	fi
fi

# ── step 2: detect and trust profile-Brewfile entries not yet in any trust ───
# Three sub-checks, each with a single prompt:
#   a) inline tap-formula/cask references in the Brewfile (brew "user/tap/pkg")
#   b) tap "user/tap" lines in the Brewfile
#   c) taps that are already installed on the system but not yet trusted
#      (brew warns about these even when the active Brewfile doesn't use them)
if command -v jq > /dev/null 2>&1; then
	# Build sorted lists of already-trusted formulae, casks and taps from both
	# trust files so we can diff against them with comm(1).
	_tf=$(mktemp)
	_tc=$(mktemp)
	_tt=$(mktemp)
	{
		[ -r "${required_trust_file}" ] && jq -r '(.trustedformulae // []) | .[]' "${required_trust_file}" 2> /dev/null || true
		[ -r "${primary_trust_file}" ] && jq -r '(.trustedformulae // []) | .[]' "${primary_trust_file}" 2> /dev/null || true
	} | sort -u > "${_tf}"
	{
		[ -r "${required_trust_file}" ] && jq -r '(.trustedcasks // []) | .[]' "${required_trust_file}" 2> /dev/null || true
		[ -r "${primary_trust_file}" ] && jq -r '(.trustedcasks // []) | .[]' "${primary_trust_file}" 2> /dev/null || true
	} | sort -u > "${_tc}"
	{
		[ -r "${required_trust_file}" ] && jq -r '(.trustedtaps // []) | .[]' "${required_trust_file}" 2> /dev/null || true
		[ -r "${primary_trust_file}" ] && jq -r '(.trustedtaps // []) | .[]' "${primary_trust_file}" 2> /dev/null || true
	} | sort -u > "${_tt}"

	# a) inline brew "user/tap/formula" references not yet trusted as formulae
	_uf=""
	if [ -r "${HOMEBREW_BUNDLE_FILE_GLOBAL}" ]; then
		_uf=$(awk -F'"' '/^brew "[^"]+"/ { n=$2; if (index(n,"/")>0) print n }' \
			"${HOMEBREW_BUNDLE_FILE_GLOBAL}" | sort -u | comm -23 - "${_tf}")
	fi

	# b) inline cask "user/tap/cask" references not yet trusted as casks
	_uc=""
	if [ -r "${HOMEBREW_BUNDLE_FILE_GLOBAL}" ]; then
		_uc=$(awk -F'"' '/^cask "[^"]+"/ { n=$2; if (index(n,"/")>0) print n }' \
			"${HOMEBREW_BUNDLE_FILE_GLOBAL}" | sort -u | comm -23 - "${_tc}")
	fi

	# b) tap "user/tap" lines in the Brewfile not yet trusted as taps
	_utap_brewfile=""
	if [ -r "${HOMEBREW_BUNDLE_FILE_GLOBAL}" ]; then
		_utap_brewfile=$(awk -F'"' '/^tap "[^"]+"/ { n=$2; if (index(n,"/")>0) print n }' \
			"${HOMEBREW_BUNDLE_FILE_GLOBAL}" | grep -v '^homebrew/' | sort -u | comm -23 - "${_tt}")
	fi

	# c) taps already installed on the system but not trusted (orphan taps)
	# brew warns about these during every bundle install regardless of which
	# formulae are in the active Brewfile, so we must trust them proactively.
	_utap_orphan=$(brew tap 2> /dev/null | grep -v '^homebrew/' | sort -u | comm -23 - "${_tt}" || true)

	# Combine both tap sets, deduplicate
	_ut=$(printf '%s\n%s\n' "${_utap_brewfile}" "${_utap_orphan}" | grep -v '^$' | sort -u || true)

	rm -f "${_tf}" "${_tc}" "${_tt}"

	# ── prompt once for formulae / casks ──────────────────────────────────────
	if [ -n "${_uf:-}" ] || [ -n "${_uc:-}" ]; then
		warn "your Brewfile includes non-official packages not yet trusted; their code runs during install:"
		{
			[ -n "${_uf:-}" ] && printf '%s\n' "${_uf}"
			[ -n "${_uc:-}" ] && printf '%s\n' "${_uc}"
		} | sed 's/^/      - /'

		if [ -r /dev/tty ]; then
			warn "trust these packages and continue? [y/N]"
			read -r _reply < /dev/tty || _reply=""
			case "${_reply}" in
			[Yy] | [Yy][Ee][Ss]) ;;
			*)
				error "aborted: profile packages not trusted"
				exit 1
				;;
			esac
		else
			warn "no tty available; skipping package-trust confirmation — install may fail"
		fi

		[ -n "${_uf:-}" ] && printf '%s\n' "${_uf}" | while IFS= read -r _f; do
			# Derive the parent tap (user/tap) from the formula path (user/tap/formula).
			# brew trust marks the formula trusted but does not tap the parent tap;
			# brew bundle install cannot resolve the formula until the tap is present.
			_tap=$(printf '%s\n' "${_f}" | sed 's|/[^/]*$||')
			if ! brew tap 2> /dev/null | grep -qx "${_tap}"; then
				info "brew tap ${_tap}"
				brew tap "${_tap}"
			fi
			info "brew trust --formula ${_f}"
			brew trust --formula "${_f}"
		done
		[ -n "${_uc:-}" ] && printf '%s\n' "${_uc}" | while IFS= read -r _c; do
			info "brew trust --cask ${_c}"
			brew trust --cask "${_c}"
		done
	fi

	# ── prompt once for untrusted taps (Brewfile + orphan) ───────────────────
	if [ -n "${_ut:-}" ]; then
		warn "the following taps are installed but not trusted; brew ignores their formulae until trusted:"
		printf '%s\n' "${_ut}" | sed 's/^/      - /'

		if [ -r /dev/tty ]; then
			warn "trust these taps and continue? [y/N]"
			read -r _reply < /dev/tty || _reply=""
			case "${_reply}" in
			[Yy] | [Yy][Ee][Ss]) ;;
			*)
				error "aborted: taps not trusted"
				exit 1
				;;
			esac
		else
			warn "no tty available; skipping tap-trust confirmation — install may fail"
		fi

		printf '%s\n' "${_ut}" | while IFS= read -r _tap; do
			info "brew trust ${_tap}"
			brew trust "${_tap}"
		done
	fi
fi

# ── step 3: build a merged trust and run the install ─────────────────────────
# Run brew bundle in a temp XDG dir whose trust.json merges the repo-required
# entries with the user's current primary trust (now including anything trusted
# in step 2).  This ensures the install respects both sources even though
# XDG_CONFIG_HOME is temporarily overridden.
_xdg_tmp=$(mktemp -d)
mkdir -p "${_xdg_tmp}/homebrew"
if command -v jq > /dev/null 2>&1; then
	if [ -r "${primary_trust_file}" ]; then
		jq -s '
			(.[0] // {}) as $r | (.[1] // {}) as $u
			| reduce (($r + $u) | keys_unsorted[]) as $k
				({}; .[$k] = ((($r[$k] // []) + ($u[$k] // [])) | unique))
		' "${required_trust_file}" "${primary_trust_file}" \
			> "${_xdg_tmp}/homebrew/trust.json" 2> /dev/null ||
			cp "${required_trust_file}" "${_xdg_tmp}/homebrew/trust.json"
	elif [ -r "${required_trust_file}" ]; then
		cp "${required_trust_file}" "${_xdg_tmp}/homebrew/trust.json"
	fi
elif [ -r "${required_trust_file}" ]; then
	cp "${required_trust_file}" "${_xdg_tmp}/homebrew/trust.json"
fi

# ── step 3b: remove broken tap directories before bundle install ─────────────
# A tap whose directory exists but whose .git/config is missing or whose git
# repo is corrupt causes `brew bundle install` to fail with "already exists and
# is not an empty directory" / "could not lock config file" errors.  Find every
# tap directory that is missing a valid git HEAD and remove it so brew can
# re-clone it cleanly.
_taps_dir="$(brew --prefix)/Library/Taps"
if [ -d "${_taps_dir}" ]; then
	find "${_taps_dir}" -mindepth 2 -maxdepth 2 -type d | while IFS= read -r _tap_dir; do
		if [ ! -f "${_tap_dir}/.git/HEAD" ]; then
			warn "removing broken tap directory: ${_tap_dir}"
			rm -rf "${_tap_dir}"
		fi
	done
fi

# Warn about installed packages absent from the Brewfile before making any changes.
# These won't be reinstalled on a fresh system — add them to your Brewfile to protect them.
_orphaned=$(XDG_CONFIG_HOME="${_xdg_tmp}" brew bundle cleanup --dry-run --global 2> /dev/null |
	grep '^Would uninstall' | sed 's/^Would uninstall [^:]*: //' | sort -u || true)
if [ -n "${_orphaned:-}" ]; then
	warn "the following installed packages are not tracked in your Brewfile and won't be reinstalled:"
	printf '%s\n' "${_orphaned}" | sed 's/^/      - /'
fi

info "installing / upgrading from brewfile..."
XDG_CONFIG_HOME="${_xdg_tmp}" brew bundle install --global
rm -rf "${_xdg_tmp}"

# Fold the required trust entries into the user's primary trust.json so later
# `brew bundle` / `brewfile` runs — which read ~/.config/homebrew/trust.json —
# already trust everything the requirements install pulled in. jq is on PATH now
# that the install (which provides it via Brewfile.requirements) has finished.
if [ -r "${required_trust_file}" ] && command -v jq > /dev/null 2>&1; then
	info "merging required trust entries into ${primary_trust_file}..."
	mkdir -p "$(dirname "${primary_trust_file}")"
	[ -e "${primary_trust_file}" ] || printf '{}\n' > "${primary_trust_file}"

	merged_trust=$(mktemp)
	if jq -s '
		(.[0] // {}) as $primary
		| (.[1] // {}) as $required
		| reduce (($primary + $required) | keys_unsorted[]) as $key
			({}; .[$key] = ((($primary[$key] // []) + ($required[$key] // [])) | unique))
	' "${primary_trust_file}" "${required_trust_file}" > "${merged_trust}"; then
		cat "${merged_trust}" > "${primary_trust_file}"
		chmod 600 "${primary_trust_file}"
	else
		warn "could not merge required trust into ${primary_trust_file}; left unchanged"
	fi
	rm -f "${merged_trust}"
fi

info "cleaning up brew cache"
brew cleanup --quiet
