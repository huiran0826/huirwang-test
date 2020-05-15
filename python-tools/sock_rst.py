import argparse
import socket
import sys
import struct
import time

parser = argparse.ArgumentParser(description='A tutorial of argparse!')
parser.add_argument("--src-port", type=int, default=11337, help="source port to use")
parser.add_argument("--dst-port", type=int, help="dst port to use")
parser.add_argument("--dst-ip", help="server ip to use")
args = parser.parse_args()
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_address = (args.dst_ip, args.dst_port)
sock.bind(('0.0.0.0', args.src_port))
sock.connect(server_address)
l_onoff = 1
l_linger = 0
time.sleep(1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', l_onoff, l_linger))
sock.close()
