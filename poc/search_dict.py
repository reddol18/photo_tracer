"""검색어 낱말 규칙(#23·#24) — 앱 SceneWords.kt와 같은 규칙. 둘을 함께 고친다.

- 한영 사전(search_dict.tsv): 검색어 낱말(공백 단위)에서 조사·'하는' 따위를 떼어 사전 꼴과 맞춘다.
- 사람 낱말: 이 낱말이 든 검색어에만 흔한 장면 방향을 뺀다.
"""
from pathlib import Path

DICT_TSV = Path(__file__).parent / "search_dict.tsv"

# 낱말 끝에서 떼어 볼 꼴(긴 것부터). 조사(Search.kt JOSA + 장소·도구 조사)와 '하다' 활용
JOSA = ["이랑", "이하고", "이와", "이가", "이는", "이를", "이의", "이도", "이만", "에게", "한테", "하고",
        "랑", "와", "과", "의", "은", "는", "이", "가", "을", "를", "도", "만",
        "에서는", "에서의", "에서도", "에서", "에는", "에도", "에의", "에", "으로", "로", "까지", "부터", "처럼", "이나", "나"]
HA = ["하는중", "하면서", "하는", "하고", "하기", "하다", "하며", "하러", "하던", "했던", "한", "중"]
SUFFIX = sorted(set(JOSA + HA), key=len, reverse=True)

# 사람 낱말(조사가 붙어도 된다). 흔한 장면 방향(GENERIC: 아이·가족 사진 문구)과 겹치는 말
PERSON = {"아이", "아이들", "애들", "아기", "애기", "아가", "꼬마", "어린이", "유아", "남자아이", "여자아이", "남자애", "여자애",
          "사람", "사람들", "모습", "가족", "친구", "친구들", "엄마", "아빠", "딸", "아들", "동생", "언니", "누나", "오빠", "형"}


def forms(word: str) -> list[str]:
    """낱말 그대로, 끝 꼴 하나를 뗀 것, 그리고 복수 '들'까지 뗀 것(인형들과 → 인형)."""
    out = [word]
    for s in SUFFIX:
        if len(word) > len(s) and word.endswith(s):
            out.append(word[: -len(s)])
    out += [f[:-1] for f in list(out) if len(f) > 1 and f.endswith("들")]
    return list(dict.fromkeys(out))


def load_dict(path: Path = DICT_TSV) -> list[tuple[str, list[str], str]]:
    """(종류, 한국어 꼴들, 영어)"""
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        kind, ko, en = line.split("\t")
        rows.append((kind, ko.split("|"), en))
    return rows


class Lexicon:
    def __init__(self, rows=None):
        self.rows = rows if rows is not None else load_dict()
        self.index: dict[str, int] = {}
        for k, (_, kos, _) in enumerate(self.rows):
            for f in kos:
                assert f not in self.index, f"사전 꼴 중복: {f}"
                self.index[f] = k

    def match(self, query: str) -> list[int]:
        """검색어 속 사전 낱말의 행 번호(처음 나온 순, 중복 없이)"""
        hit = []
        for w in query.split():
            k = next((self.index[f] for f in forms(w) if f in self.index), None)
            if k is not None and k not in hit:
                hit.append(k)
        return hit


def has_person(query: str) -> bool:
    return any(f in PERSON for w in query.split() for f in forms(w))
