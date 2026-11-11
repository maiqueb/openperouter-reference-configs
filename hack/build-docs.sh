#!/usr/bin/env bash
#
# Render the AsciiDoc assemblies under docs/assemblies/ into a static HTML
# site in docs/build/, plus an index page linking each rendered guide.
#
# The GitHub Actions workflow (.github/workflows/docs.yml) runs this script
# and publishes docs/build/ to GitHub Pages.
#
# Local usage:
#   bundle install && bundle exec ./hack/build-docs.sh
# or, without Ruby installed:
#   podman run --rm -v "$PWD":/documents -w /documents \
#       --user "$(id -u):$(id -g)" \
#       docker.io/asciidoctor/docker-asciidoctor:latest ./hack/build-docs.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src_dir="$repo_root/docs/assemblies"
out_dir="$repo_root/docs/build"
asciidoctor="${ASCIIDOCTOR:-asciidoctor}"

if ! command -v "$asciidoctor" >/dev/null 2>&1; then
  echo "error: '$asciidoctor' not found; run 'bundle install' and use 'bundle exec $0'" >&2
  exit 1
fi

shopt -s nullglob
assemblies=("$src_dir"/*.adoc)
shopt -u nullglob

if (( ${#assemblies[@]} == 0 )); then
  echo "error: no assemblies found in $src_dir" >&2
  exit 1
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"

entries=()
for src in "${assemblies[@]}"; do
  name="$(basename "$src" .adoc)"
  "$asciidoctor" \
    --backend html5 \
    --attribute lang=en \
    --attribute toc=left \
    --out-file "$out_dir/$name.html" \
    "$src"

  title="$(sed -n 's/^= //p' "$src" | head -n 1)"
  entries+=("<li><a href=\"$name.html\">${title:-$name}</a></li>")
done

{
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenPERouter reference configurations</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0 auto; max-width: 42rem; padding: 3rem 1rem;
         font-family: system-ui, sans-serif; line-height: 1.5; }
  h1 { font-size: 1.6rem; margin-bottom: .25rem; }
  p.sub { margin-top: 0; opacity: .7; }
  ul { padding-left: 1.25rem; }
  li { margin: .5rem 0; }
  a { color: #0b5cad; }
  @media (prefers-color-scheme: dark) { a { color: #6cb6ff; } }
</style>
</head>
<body>
<h1>OpenPERouter reference configurations</h1>
<p class="sub">Rendered guides</p>
<ul>
HTML
  printf '  %s\n' "${entries[@]}"
  cat <<'HTML'
</ul>
</body>
</html>
HTML
} > "$out_dir/index.html"

echo "Rendered ${#assemblies[@]} assembly(ies) to $out_dir"
