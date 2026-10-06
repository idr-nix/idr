_: {
  perSystem = {
    config,
    options,
    pkgs,
    ...
  }: {
    packages.mk-api-docs = pkgs.runCommand "api-documentation" {} ''
      mkdir -p $out
      cat > $out/api.md <<'EOF'
      # Example API

      Send a GET request to /health to read the service status.
      EOF
    '';

    idr.documentation.mk-docs = options.idr.documentation.mk-docs.default.overrideAttrs (old: {
      preBuild =
        (old.preBuild or "")
        + ''
          mkdir -p docs
          cp ${config.packages.mk-api-docs}/api.md docs/api.md
        '';
    });
  };
}
