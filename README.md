# sfmt-rainbow

## これは何？

第7世代のポケモンの時計の針から初期seedを求めるプログラムです。
これを実現するのはおだんぽよさんのWeb API (https://odanpoyo.github.io/2018/03/23/rng-api2/ )を使うのが一般的ですが、このプログラムはそれに依存しません。

レインボーテーブル (https://ja.wikipedia.org/wiki/%E3%83%AC%E3%82%A4%E3%83%B3%E3%83%9C%E3%83%BC%E3%83%86%E3%83%BC%E3%83%96%E3%83%AB )の技術を利用しています。
各step∈{417, 477, 1012, 1132}ごとに約100MBのテーブルを使います。
仕組み上必ず初期seedが見つかるわけではないですが、96%ぐらいは成功します (実験したところ300回中288回成功しました)。
検索は6秒(並列化したもの) or 39秒(without 並列化)程度で終わります。

おだんぽよさんのAPIを使えばいいので実用性はあまりないです。

## 使い方

テーブル生成プログラムはMetalを利用しているため、Macでのみビルドできます。

```
$ source compile.sh
```

でコンパイル。

```
$ ./create_rainbow 417
```

で417.binというテーブルを作成します (M1 Macだと9時間半かかりました)。

```
$ ./sort-rainbow 417
```

で先程生成した417.binの内容をソートし417.sorted.binを出力します。

```
$ ./search_rainbow_metal 417
```

で検索ができます (標準入力から針の値をスペース区切りで入力を求められます)


## アップロードしたテーブルを使う方法

Releases (https://github.com/fujidig/sfmt-rainbow/releases )からテーブルをダウンロードできます (まだ417しかアップロードしてません)。

Macの場合は上で書いたように並列化したsearch_rainbow_metalが使えるので上の手順でテーブル作成とソート以外をすればいいです。

WindowsやLinuxではsearch_rainbow.cppをビルドして実行します。

```
$ g++ search_rainbow.cpp ./SFMT/SFMT.c gen_hash.cpp -o search_rainbow -DSFMT_MEXP=19937
$ ./search_rainbow 417
```
