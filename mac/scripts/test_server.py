#!/usr/bin/env python3
import urllib.request
import json
import sys

def test_http():
    url = "http://127.0.0.1:8765/"
    print(f"Testing HTTP GET {url}...")
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            content = resp.read().decode('utf-8')
            if "Galaxy Continuity" in content:
                print("✅ HTTP Web Companion served successfully!")
                return True
            else:
                print("❌ Unexpected content received.")
                return False
    except Exception as e:
        print(f"❌ Connection failed: {e}")
        return False

if __name__ == "__main__":
    success = test_http()
    sys.exit(0 if success else 1)
