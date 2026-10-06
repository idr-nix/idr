_: {
  flake.modules.nixos.documentation-example = {
    lib,
    serviceDefaults,
    ...
  }: {
    options.services.documentationExample.endpoint = lib.mkOption {
      type = lib.types.str;
      default = serviceDefaults.endpoint;
      description = "Endpoint used by the documentation example service.";
    };
  };

  perSystem.idr.documentation.specialArgs.nixos.serviceDefaults.endpoint = "https://api.example.invalid";
}
