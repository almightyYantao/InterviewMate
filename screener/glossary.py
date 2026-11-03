"""语音识别用的术语表：从报告里抽英文 / 技术词，再加一份内置的网络术语。"""
from __future__ import annotations

import re

from . import config
from .schemas import Report

# 网络工程面试常说的词（大小写按习惯写法）
NETWORK = [
    "OSPF", "BGP", "IS-IS", "EIGRP", "RIP", "VRRP", "HSRP", "STP", "RSTP", "MSTP", "LACP", "VLAN", "VXLAN", "QinQ",
    "MPLS", "SD-WAN", "IPsec", "GRE", "L2TP", "SSL VPN", "WireGuard", "NAT", "PAT", "ACL", "QoS", "DSCP", "PBR",
    "DHCP", "DNS", "NTP", "SNMP", "Syslog", "NetFlow", "sFlow", "LLDP", "ARP", "ICMP", "TCP", "UDP", "MTU", "MSS",
    "IPv4", "IPv6", "Anycast", "ECMP", "BFD", "route-map", "prefix-list", "AS-path", "Area 0", "LSA",
    "802.1X", "802.1Q", "RADIUS", "TACACS+", "NAC", "Portal", "MAB", "WPA2", "WPA3", "SSID", "AP", "AC", "Wi-Fi 6",
    "漫游", "信道", "Mesh", "PoE", "光模块", "单模", "多模", "核心交换机", "汇聚", "接入层", "堆叠", "链路聚合",
    "防火墙", "上网行为管理", "零信任", "ZTNA", "WAF", "IDS", "IPS", "DDoS", "VPN", "专线", "MSTP 专线", "SLA",
    "Fortinet", "FortiGate", "Palo Alto", "Cisco", "Juniper", "Arista", "华为", "华三", "H3C", "锐捷", "深信服",
    "UniFi", "Ubiquiti", "Aruba", "Meraki", "Zabbix", "Prometheus", "Grafana", "Ansible", "Python", "Wireshark",
    "tcpdump", "traceroute", "ping", "iperf", "CCNA", "CCNP", "CCIE", "HCIE", "AWS", "Azure", "VPC", "Direct Connect",
]

_TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9+./\-]*[A-Za-z0-9+]|\d+(?:\.\d+)+[A-Za-z]*")


def extract(texts: list[str]) -> list[str]:
    """抽出文本里的英文缩写、产品名、协议号（如 OSPF、FortiGate、802.1X），按出现次数排序"""
    cnt: dict[str, int] = {}
    for t in texts:
        for w in _TOKEN.findall(t or ""):
            if len(w) >= 2 and not w.isdigit():
                cnt[w] = cnt.get(w, 0) + 1
    return sorted(cnt, key=lambda w: -cnt[w])


def custom() -> list[str]:
    raw = config.get().get("speech_terms", "")
    return [w.strip() for w in re.split(r"[,，、\n]", raw) if w.strip()]


def for_report(r: Report, limit: int = 120) -> list[str]:
    texts = [r.position] + [q.text for q in r.jd.requirements]
    for q in r.questions:
        texts += [q.question, *q.answer_points, *q.follow_ups]
    seen: set[str] = set()
    out: list[str] = []
    # 自定义词最优先，其次是这份报告里出现的词，最后是内置词表
    for w in custom() + extract(texts) + NETWORK:
        if w.lower() not in seen:
            seen.add(w.lower())
            out.append(w)
    return out[:limit]
