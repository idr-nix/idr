module Main (main) where

import Control.Monad (join)
import Data.String (IsString, fromString)
import IDR.Mesh.Addresses qualified as Addresses
import IDR.Mesh.Agent qualified as Agent
import IDR.Mesh.Dns.Transport qualified as DnsTransport
import IDR.Mesh.Duration (parseSeconds)
import IDR.Mesh.Etcd.Config (Server (..))
import IDR.Mesh.Health qualified as Health
import IDR.Mesh.Identity (MeshPrefix, parseMeshPrefix)
import IDR.Mesh.Instance qualified as Instance
import IDR.Mesh.Namespace qualified as NS
import IDR.Mesh.Netd qualified as Netd
import IDR.Mesh.Netd.Server qualified as Server
import IDR.Mesh.Port (parsePort)
import IDR.Mesh.Status qualified as Status
import Options.Applicative

main :: IO ()
main = join (customExecParser (prefs showHelpOnEmpty) parser)
  where
    description = progDesc "Manage the IDR WireGuard service mesh"
    parser = info (commands <**> helper) (fullDesc <> description)

commands :: Parser (IO ())
commands =
  subcommands
    [ subcommand "agent" agentHelp (Agent.run <$> agent),
      subcommand "health" "Answer WireGuard UDP health probes" (pure Health.serve),
      subcommand "netd" "Serve privileged mesh requests on the activated socket" $
        Server.serve <$> netd,
      subcommand "ctl" "Send a request to idr-mesh netd" ctl,
      subcommand "status" "Print each workload's mesh state as JSON; needs root" (pure Status.printStatus),
      subcommand "metrics" "Write mesh metrics for node-exporter's textfile collector; needs root" $
        Status.writeMetrics <$> arg "FILE",
      subcommand "dns-transport" "Manage the isolated mesh DNS namespace and links" dnsTransport
    ]
  where
    agentHelp = "Collect host addresses, and register and retire this host's mesh instances"

agent :: Parser Agent.Config
agent = Agent.Config <$> registrar <*> many publicAddress
  where
    registrar =
      Instance.Registrar
        <$> meshPrefix
        <*> readArg "HEALTH-PORT" parsePort
        <*> readArg "LEASE-TTL-SECONDS" (parseSeconds 1 9_000_000_000)
        <*> server
    publicAddress =
      option (eitherReader Addresses.parseAddress) $
        long "public-address"
          <> metavar "ADDRESS"
          <> help "Advertise this address instead of discovering public addresses"

netd :: Parser Server.Config
netd =
  Server.Config
    <$> meshPrefix
    <*> readArg "FIRST-PORT" parsePort
    <*> readArg "LAST-PORT" parsePort

ctl :: Parser (IO ())
ctl =
  subcommands
    [ subcommand "up" "Create a workload's namespace, keys, port and declarations" $
        send Netd.Up,
      subcommand "down" "Remove a workload's namespace" $
        Netd.requestDown <$> service,
      subcommand "apply" "Apply a workload's declarations and stored desired state again" $
        send Netd.Apply
    ]
  where
    service = readArg "SERVICE" NS.parseService
    send request = Netd.request . request <$> service

dnsTransport :: Parser (IO ())
dnsTransport =
  subcommands
    [ subcommand "create-dns" "Create the shared DNS namespace" $
        DnsTransport.createDns <$> arg "RULES",
      subcommand "configure-dns" "Configure the DNS namespace and apply its firewall" $
        DnsTransport.configureDns <$> arg "RULES",
      subcommand "remove-dns" "Remove the shared DNS namespace" (pure DnsTransport.removeDns),
      subcommand "create-link" "Connect a service to its DNS interface" $
        DnsTransport.createLink <$> arg "SERVICE" <*> arg "INVENTORY" <*> arg "STATE",
      subcommand "remove-link" "Remove a service's DNS link and firewall" $
        DnsTransport.removeLink <$> arg "SERVICE" <*> arg "INVENTORY" <*> arg "STATE"
    ]

server :: Parser Server
server = Server <$> arg "ENDPOINT" <*> arg "USER" <*> arg "PASSWORD-FILE"

meshPrefix :: Parser MeshPrefix
meshPrefix = readArg "PREFIX" (parseMeshPrefix . fromString)

arg :: (IsString a) => String -> Parser a
arg name = strArgument (metavar name)

readArg :: String -> (String -> Either String a) -> Parser a
readArg name readValue = argument (eitherReader readValue) (metavar name)

type Command = Mod CommandFields (IO ())

subcommand :: String -> String -> Parser (IO ()) -> Command
subcommand name description parser = command name (info (parser <**> helper) (progDesc description))

subcommands :: [Command] -> Parser (IO ())
subcommands = subparser . mconcat
