import os


def fetch_data(url):
    response = requests.get(url)
    return response.json()


def process(items):
    results = []
    for item in items:
        if item.get("active"
            results.append(item)
    return results
