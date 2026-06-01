#!/usr/bin/env python3

import argparse
import logging
import xml.etree.ElementTree
import os
import glob
import subprocess

import requests

parser = argparse.ArgumentParser("huaweicheck", "Check and handle Huawei E3372 device hangs", formatter_class=argparse.ArgumentDefaultsHelpFormatter)

parser.add_argument("-v", "--verbose", help="increase verbosity", action="store_true", default=False)
parser.add_argument("--huawei-addr", help="Huawei address", default="192.168.8.1")
parser.add_argument("--global-addr", help="Global address", default="8.8.8.8")
parser.add_argument("--timeout", help="Timeout for requests", type=float, default=10)

parser.add_argument("--ping-huawei", help="Check ping of huawei device", default=True, action=argparse.BooleanOptionalAction)
parser.add_argument("--ping-global", help="Check ping of global adddress", default=True, action=argparse.BooleanOptionalAction)
parser.add_argument("--force-reset", help="Ignore ping results and force reset", default=False, action=argparse.BooleanOptionalAction)
parser.add_argument("--uhubctl-reset", help="use uhubctl for reset", default=True, action=argparse.BooleanOptionalAction)
parser.add_argument("--api-reset", help="use huawei http api for reset", default=False, action=argparse.BooleanOptionalAction)


class USBDevice:
    def __init__(self, usb_path: str):
        self.usb_path = usb_path

    @property
    def idVendor(self) -> str:
        return open(os.path.join("/sys/bus/usb/devices", self.usb_path, "idVendor"), encoding="ascii").read()[:-1]

    @property
    def idProduct(self) -> str:
        return open(os.path.join("/sys/bus/usb/devices", self.usb_path, "idProduct"), encoding="ascii").read()[:-1]

    @property
    def manufacturer(self) -> str:
        return open(os.path.join("/sys/bus/usb/devices", self.usb_path, "manufacturer"), encoding="ascii").read()[:-1]

    @property
    def product(self) -> str:
        return open(os.path.join("/sys/bus/usb/devices", self.usb_path, "product"), encoding="ascii").read()[:-1]

    @property
    def name(self) -> str:
        return self.manufacturer + " " + self.product

    def __str__(self):
        return f"{self.name} ({self.idVendor}:{self.idProduct}) @ {self.usb_path}"


class HuaweiDevice(USBDevice):
    COMPATIBLE = {
        # {Vendor: {Product: Name}}
        "12d1":  # Huawei
        {
            "14dc": "Huawei E3372s-153",
            "14db": "Huawei E3372s-320",
        },
        "3566":  # Brovi
        {
            "2001": "Brovi E3372-325",
        },
    }

    @property
    def is_compatible(self) -> bool:
        return (self.idVendor in HuaweiDevice.COMPATIBLE) and (self.idProduct in HuaweiDevice.COMPATIBLE[self.idVendor])

    @property
    def product_name(self) -> str:
        if self.is_compatible:
            return HuaweiDevice.COMPATIBLE[self.idVendor][self.idProduct]
        else:
            return ""

    @property
    def net(self):
        ifaces = glob.glob(f"/sys/bus/usb/devices/{self.usb_path}:*/net/*")
        if not ifaces:
            return None

        return os.path.basename(ifaces[0])

    def interface_class(self, interface: str = "1.0"):
        return open(os.path.join("/sys/bus/usb/devices", f"{self.usb_path}:{interface}", "bInterfaceClass"), encoding="ascii").read()[:-1]

    def ping(self, target: str, count: int = 10) -> int:
        if not self.net:
            return 1

        # define basic ping command
        cmd = ["ping", target, "-c", f"{count}"]
        if self.net:
            cmd += ["-I", self.net]

        logging.info("Running ping test: `%s`", " ".join(cmd))
        p = subprocess.Popen(cmd)
        p.wait()
        if not p.returncode:
            logging.info("Ping succeeded.")

        return p.returncode

    def uhubctl_reset(self, select_port: bool = False) -> int:
        location, port = self.usb_path.split(".")

        cmd = ["uhubctl", "--location", location, "--action", "2"]
        if select_port:
            cmd += ["--port", port]

        logging.debug("Power cycling: `%s`", " ".join(cmd))
        p = subprocess.Popen(cmd)
        p.wait()
        if p.returncode:
            logging.warning("Device %s cycling failed (%s), please check if hardware is working", location, p.returncode)

        return p.returncode

    @staticmethod
    def api_reset(target: str, timeout: float) -> int:
        logging.info("Resetting via Huawei API")
        session = requests.session()

        session.get(f"http://{target}/", timeout=timeout)
        logging.debug("Session cookies: %s", session.cookies)

        tokinfo_resp = session.get(f"http://{target}/api/webserver/SesTokInfo", timeout=timeout)
        token = xml.etree.ElementTree.fromstring(tokinfo_resp.content).find("TokInfo").text
        logging.debug("__RequestVerificationToken: %s", token)

        post_resp = session.post(
            f"http://{target}/api/device/control",
            data="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Control>1</Control></request>",
            headers={"__RequestVerificationToken": token},
            timeout=timeout,
        )

        logging.debug(post_resp.content)
        post_xml = xml.etree.ElementTree.fromstring(post_resp.content)

        if post_xml.tag == "error":
            logging.info("Reseting huawei failed: %s (%s)", post_xml.find("message").text, post_xml.find("code").text)
            return 1
        else:
            logging.info("Reseting huawei successful.")
            return 0


def find_devices() -> list[HuaweiDevice]:
    devices = []

    for sysfs_path in glob.glob("/sys/bus/usb/devices/*"):
        usb_path = os.path.basename(sysfs_path)
        if ":" in usb_path:
            continue

        dev = HuaweiDevice(usb_path)
        if dev.is_compatible:
            logging.info("Found %s", dev)
            devices.append(dev)

    return devices


if __name__ == "__main__":
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    devices = find_devices()
    if not devices:
        logging.warning("Didn't find huawei device, exiting...")
        exit(0)

    device = devices[0]
    if len(devices) > 1:
        logging.warning("Found multiple devices, only using %s", devices[0])

    reset = args.force_reset
    uhubctl_reset = args.uhubctl_reset
    api_reset = args.api_reset

    if not reset and args.ping_huawei and device.ping(args.huawei_addr, count=1):
        logging.info("Couldn't ping device, requesting uhubctl reset...")
        reset = True
        uhubctl_reset = True
        api_reset = False

    if not reset and args.ping_global and device.ping(args.global_addr):
        logging.info("Couldn't ping global address, requesting reset...")
        reset = True

    if reset and api_reset:
        if device.api_reset(args.huawei_addr, args.timeout):
            logging.warning("API Device reset failed, requesting uhubctl reset...")
            uhubctl_reset = True

    if reset and uhubctl_reset:
        logging.info("Running uhubctl reset...")
        device.uhubctl_reset()

    logging.info("Finished.")
