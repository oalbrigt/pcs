import socket

from tornado.iostream import IOStream

from pcs.daemon import log

async def notify(socket_name):
    if socket_name[0] == '@':
        # abstract namespace socket
        socket_name = '\0' + socket_name[1:]

    log.pcsd.info(f"Notifying systemd we are running (socket '{socket_name}')")
    try:
        stream = IOStream(socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM))
        await stream.connect(socket_name)
        await stream.write(b'READY=1')
        stream.close()
    except Exception as e:
        log.pcsd.error(f"Unable to notify systemd on '{socket_name}': {e}")
