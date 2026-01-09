xcrun -sdk macosx metal -c rainbow.metal -o rainbow.air
xcrun -sdk macosx metallib rainbow.air -o default.metallib
clang++ -O3 create_rainbow.mm -o create_rainbow \
  -std=c++17 \
  -framework Metal \
  -framework Foundation \
  -framework CoreGraphics
clang -c -O3 SFMT/SFMT.c -o SFMT.o -DSFMT_MEXP=19937
clang++ -O3 test_rainbow.mm SFMT.o -o test_rainbow \
  -std=c++17 \
  -framework Metal \
  -framework Foundation
clang++ -O3 sort_rainbow.cpp SFMT.o gen_hash.cpp -o sort_rainbow
clang++ -O3 search_rainbow.cpp SFMT.o gen_hash.cpp -o search_rainbow
clang++ -O3 test.cpp SFMT.o gen_hash.cpp -o test
clang++ -O3 search_rainbow.mm SFMT.o gen_hash.cpp -o search_rainbow_metal \
  -std=c++17 \
  -framework Metal \
  -framework Foundation
