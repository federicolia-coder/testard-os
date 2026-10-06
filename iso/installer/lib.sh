# shellcheck shell=sh disable=SC2034 # used by the scripts that source this
# Shared by the installer's CGI scripts (busybox httpd runs them as root,
# listening on 127.0.0.1 only).

RUN=/run/testard
INSTALL=/etc/testard/testard-install

json_str() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

reply() { # reply STATUS JSON
	printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n%s\n' "$1" "$2"
	exit 0
}

fail() { reply "$1" "{\"error\":\"$(json_str "$2")\"}"; }

require_post() { [ "${REQUEST_METHOD:-}" = POST ] || fail "405 Method Not Allowed" "use POST"; }

# URL-decodes a form value: + is a space, %XX a byte. Newlines are dropped,
# since every value ends up on one line of a KEY=value file.
urldecode() {
	printf '%s' "$1" | awk '
		BEGIN { for (i = 0; i < 256; i++) hex[sprintf("%02X", i)] = i }
		{
			s = $0; gsub(/\+/, " ", s); out = ""
			while ((p = index(s, "%")) > 0) {
				h = toupper(substr(s, p + 1, 2))
				if (h in hex) { out = out substr(s, 1, p - 1) sprintf("%c", hex[h]); s = substr(s, p + 3) }
				else { out = out substr(s, 1, p); s = substr(s, p + 1) }
			}
			printf "%s", out s
		}' | tr -d '\r\n'
}

# Reads the POST body into FORM (one key=value per line, still encoded).
read_form() {
	n=${CONTENT_LENGTH:-0}
	[ "$n" -le 65536 ] 2>/dev/null || fail "413 Payload Too Large" "too much data"
	FORM=$(head -c "$n" | tr '&' '\n')
}

field() { # field NAME: the decoded value of NAME from FORM
	urldecode "$(printf '%s\n' "$FORM" | sed -n "s/^$1=//p" | head -n 1)"
}
