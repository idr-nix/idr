{
  haskell,
  haskellPackages,
  protobuf,
}:
haskellPackages.extend (_: previous: {
  # The supplied Setup.hs generates the Haskell API from etcd's .proto files.
  proto-lens-etcd = haskell.lib.overrideCabal previous.proto-lens-etcd (old: {
    broken = false;
    libraryToolDepends = (old.libraryToolDepends or []) ++ [protobuf];
  });
})
