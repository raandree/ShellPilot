function New-ShpMcpHttpHandler {
    <#
    .SYNOPSIS
        Builds the hardened HTTP handler the built-in remote MCP transport
        sends through, pinned to an approved address set.

    .DESCRIPTION
        Private helper holding everything the built-in transport turns OFF, and
        the one thing it turns on.

        Off: automatic redirects, because a redirect has to be re-validated by
        this module before it is followed; cookies, because a third-party
        endpoint does not get a jar; the proxy, default credentials, proxy
        credentials and pre-authentication, because none of them are the
        caller's decision to hand to a server that asked.

        On: a connect callback that opens the socket to an address this module
        already approved, and to nothing else. The handler is never given the
        chance to resolve the host itself, which is what makes the approval mean
        something at the moment of the connection rather than a moment before
        it.

        The request keeps the host name, so TLS, SNI, certificate validation and
        the Host header are all unchanged - the peer still has to present a
        certificate for the name the caller attached. Nothing here relaxes
        validation, and putting the address in the URL instead would have done
        exactly that, because the certificate would then have to match the
        address.

        The connector is a small compiled type rather than a scriptblock. A
        connect callback is invoked on a thread the HTTP stack owns, where a
        PowerShell scriptblock has no runspace to run in; a compiled delegate is
        the only shape that can answer there at all.

    .PARAMETER Address
        The approved addresses, in preference order. The socket goes to one of
        these or to nowhere.

    .PARAMETER Port
        The port the endpoint was approved on.

    .EXAMPLE
        New-ShpMcpHttpHandler -Address @('93.184.216.34') -Port 443

        Returns a handler that connects only to that address while the request
        still names the host.

    .OUTPUTS
        System.Net.Http.SocketsHttpHandler

        A handler carrying no ambient identity and a pinned connect callback.

    .LINK
        Resolve-ShpMcpSocketAddress

    .LINK
        New-ShpMcpHttpChannel
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpMcpHttpHandler assembles an in-memory handler; the attachment that changes session state is Register-ShpMcpServer, which declares SupportsShouldProcess.')]
    [OutputType([System.Net.Http.SocketsHttpHandler])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Address,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    if (-not ('ShellPilot.PinnedConnector' -as [type])) {
        # Compiled on first use and kept for the life of the process. A remote
        # attachment is rare enough that paying for the compile once is cheaper
        # than paying for it at import for every session that never attaches.
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace ShellPilot
{
    /// <summary>Opens a socket only to an address ShellPilot already approved.</summary>
    public sealed class PinnedConnector
    {
        private readonly IPAddress[] _address;
        private readonly int _port;

        public PinnedConnector(string[] address, int port)
        {
            if (address == null || address.Length == 0)
            {
                throw new ArgumentException("A pinned connector needs at least one approved address.", "address");
            }
            if (port < 1 || port > 65535)
            {
                throw new ArgumentOutOfRangeException("port", "A pinned connector needs the port the endpoint was approved on.");
            }
            IPAddress[] parsed = new IPAddress[address.Length];
            for (int i = 0; i < address.Length; i++)
            {
                parsed[i] = IPAddress.Parse(address[i]);
            }
            _address = parsed;
            _port = port;
        }

        public string[] ApprovedAddress
        {
            get
            {
                string[] result = new string[_address.Length];
                for (int i = 0; i < _address.Length; i++) { result[i] = _address[i].ToString(); }
                return result;
            }
        }

        public int Port { get { return _port; } }

        /// <summary>The connect callback. The requested host is deliberately ignored.</summary>
        public async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken cancellationToken)
        {
            Exception last = null;
            foreach (IPAddress address in _address)
            {
                cancellationToken.ThrowIfCancellationRequested();
                Socket socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                socket.NoDelay = true;
                try
                {
                    await socket.ConnectAsync(new IPEndPoint(address, _port), cancellationToken).ConfigureAwait(false);
                    return new NetworkStream(socket, true);
                }
                catch (Exception error)
                {
                    last = error;
                    socket.Dispose();
                }
            }
            throw new IOException("No address approved for this MCP endpoint accepted the connection.", last);
        }

        public Func<SocketsHttpConnectionContext, CancellationToken, ValueTask<Stream>> Callback
        {
            get { return ConnectAsync; }
        }
    }
}
'@ -ErrorAction Stop
    }

    $connector = [ShellPilot.PinnedConnector]::new([string[]]@($Address), $Port)

    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseProxy = $false
    $handler.Proxy = $null
    $handler.Credentials = $null
    $handler.DefaultProxyCredentials = $null
    $handler.PreAuthenticate = $false
    $handler.ConnectCallback = $connector.Callback
    $handler
}
