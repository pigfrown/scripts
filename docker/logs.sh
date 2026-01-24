logs() {
  local query="${1:-}"
  local containers=()
  local id name

  # Collect matching running containers
  if [[ -n "$query" ]]; then
    mapfile -t containers < <(
      docker ps \
        --filter "name=$query" \
        --format "{{.ID}} {{.Names}}"
    )
  else
    mapfile -t containers < <(
      docker ps \
        --format "{{.ID}} {{.Names}}"
    )
  fi

  if [[ "${#containers[@]}" -eq 0 ]]; then
    echo "❌ No matching running containers found"
    return 1
  fi

  # If more than one container, try fzf
  if [[ "${#containers[@]}" -gt 1 ]]; then
    if command -v fzf >/dev/null 2>&1; then
      id=$(printf '%s\n' "${containers[@]}" \
        | fzf --prompt="Select container logs ▶ " \
        | awk '{print $1}')
    else
      echo "❌ Multiple containers match:"
      printf '  %s\n' "${containers[@]}"
      echo
      echo "Tip: install fzf or pass a more specific name."
      return 1
    fi
  else
    id="${containers[0]%% *}"
  fi

  if [[ -z "$id" ]]; then
    echo "❌ No container selected"
    return 1
  fi

  name=$(docker ps --filter "id=$id" --format "{{.Names}}")

  echo "📦 Following logs for: $name ($id)"
  echo

  docker logs -f --timestamps "$id"
}

