{
  idr-generate-docs,
  mk-docs,
}: {...}: {
  packagesFrom = [mk-docs];

  devshell.startup.idr-generate-docs = {
    text = ''
      mkdir -p "$PRJ_DATA_DIR"
      if [[ -w "$PRJ_ROOT" ]] &&
        [[ ! -d "$PRJ_ROOT/docs/generated" ||
          "$(readlink -f "$PRJ_DATA_DIR/idr-generate-docs")" != "$(readlink -f ${idr-generate-docs})" ]]; then
        rm -f "$PRJ_DATA_DIR/idr-generate-docs"
        (cd "$PRJ_ROOT" && ${idr-generate-docs}/bin/idr-generate-docs) &&
          ln -Tfs "${idr-generate-docs}" "$PRJ_DATA_DIR/idr-generate-docs"
      fi
    '';
  };
}
