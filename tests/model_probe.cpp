#include "predictor.hpp"
#include <fstream>
#include <array>
int main(int argc,char** argv) {
    if(argc!=3)return 2;
    std::ifstream input(argv[1],std::ios::binary);
    std::ofstream output(argv[2],std::ios::binary|std::ios::trunc);
    if(!input||!output)return 3;
    spectral::GainPredictor model;
    std::array<float,64> features{},prediction{};
    while(input.read(reinterpret_cast<char*>(features.data()),sizeof(features))) {
        model.infer(features.data(),prediction.data());
        output.write(reinterpret_cast<const char*>(prediction.data()),sizeof(prediction));
    }
    return input.eof() && input.gcount()==0 && output ? 0 : 4;
}
