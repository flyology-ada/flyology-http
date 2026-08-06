#include <ada.h>

#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using clock_type = std::chrono::steady_clock;

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3) {
    std::cerr << "usage: ada_url_benchmark CORPUS [ROUNDS]\n";
    return 2;
  }
  const int rounds = argc == 3 ? std::stoi(argv[2]) : 5;
  std::ifstream input(argv[1]);
  std::vector<std::string> urls;
  for (std::string line; std::getline(input, line);) {
    if (!line.empty()) urls.push_back(std::move(line));
  }
  std::uint64_t accepted = 0;
  std::uint64_t href_bytes = 0;
  auto began = clock_type::now();
  for (int round = 0; round < rounds; ++round) {
    for (const auto& text : urls) {
      if (ada::can_parse(text)) ++accepted;
    }
  }
  auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
      clock_type::now() - began).count();
  const auto total = static_cast<std::uint64_t>(rounds) * urls.size();
  std::cout << "ada_url,can_parse," << urls.size() << ','
            << accepted / rounds << ',' << elapsed / total << '\n';

  accepted = 0;
  began = clock_type::now();
  for (int round = 0; round < rounds; ++round) {
    for (const auto& text : urls) {
      auto parsed = ada::parse<ada::url_aggregator>(text);
      if (parsed) {
        ++accepted;
        href_bytes += parsed->get_href().size();
      }
    }
  }
  elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
      clock_type::now() - began).count();
  std::cout << "ada_url,parse_href," << urls.size() << ','
            << accepted / rounds << ',' << elapsed / total << '\n';
  if (href_bytes == UINT64_MAX) std::cout << "unreachable\n";
}
