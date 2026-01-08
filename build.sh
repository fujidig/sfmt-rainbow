xcrun -sdk macosx metal -c rainbow.metal -o rainbow.air
xcrun -sdk macosx metallib rainbow.air -o default.metallib
clang++ -O3 create_rainbow.mm -o create_rainbow \
  -std=c++17 \
  -framework Metal \
  -framework Foundation \
  -framework CoreGraphics
clang++ -O3 test_rainbow.mm ./SFMT/SFMT.c -o test_rainbow \
  -std=c++17 \
  -DSFMT_MEXP=19937 \
  -framework Metal \
  -framework Foundation -DSFMT_MEXP=19937
clang++ -O3 sort_rainbow.cpp ./SFMT/SFMT.c gen_hash.cpp -o sort_rainbow -DSFMT_MEXP=19937
clang++ -O3 search_rainbow.cpp ./SFMT/SFMT.c gen_hash.cpp -o search_rainbow -DSFMT_MEXP=19937
clang++ -O3 test.cpp ./SFMT/SFMT.c gen_hash.cpp -o test -DSFMT_MEXP=19937
clang++ -O3 search_rainbow.mm ./SFMT/SFMT.c gen_hash.cpp -o search_rainbow_metal \
  -std=c++17 \
  -DSFMT_MEXP=19937 \
  -framework Metal \
  -framework Foundation
