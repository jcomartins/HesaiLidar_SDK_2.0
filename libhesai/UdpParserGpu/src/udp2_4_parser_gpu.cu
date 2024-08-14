/************************************************************************************************
Copyright (C) 2023 Hesai Technology Co., Ltd.
Copyright (C) 2023 Original Authors
All rights reserved.

All code in this repository is released under the terms of the following Modified BSD License. 
Redistribution and use in source and binary forms, with or without modification, are permitted 
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and 
  the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and 
  the following disclaimer in the documentation and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its contributors may be used to endorse or 
  promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED 
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR 
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR 
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF 
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
************************************************************************************************/

#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <cuda_device_runtime_api.h>

#include "udp2_4_parser_gpu.h"
#include "safe_call.cuh"
#include "return_code.h"

using namespace hesai::lidar;
template <typename T_Point>
Udp2_4ParserGpu<T_Point>::Udp2_4ParserGpu() {
  corrections_loaded_ = false;
  cudaSafeMalloc(raw_azimuths_cu_, kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(float));
  cudaSafeMalloc(raw_elevations_cu_, kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(float));
  cudaSafeMalloc(raw_distances_cu_, sizeof(PointCloudStruct<T_Point>::distances));
  cudaSafeMalloc(raw_reflectivities_cu_, sizeof(PointCloudStruct<T_Point>::reflectivities));
  cudaSafeMalloc(raw_sensor_timestamp_cu_, sizeof(PointCloudStruct<T_Point>::sensor_timestamp));
}
template <typename T_Point>
Udp2_4ParserGpu<T_Point>::~Udp2_4ParserGpu() {
  cudaSafeFree(raw_azimuths_cu_);
  cudaSafeFree(raw_elevations_cu_);
  cudaSafeFree(raw_distances_cu_);
  cudaSafeFree(raw_reflectivities_cu_);
  if (corrections_loaded_) {
    cudaSafeFree(channel_elevations_cu_);
    cudaSafeFree(channel_azimuths_cu_);
    corrections_loaded_ = false;
  }
}
template <typename T_Point>
__global__ void compute_xyzs_2_4_impl(T_Point *xyzs, const float* channel_azimuths, const float* channel_elevations,
    const float* raw_azimuths, const float* raw_elevations, const uint16_t *raw_distances, const uint8_t *raw_reflectivities, 
    const uint64_t *raw_sensor_timestamp, const double raw_distance_unit, Transform transform, const uint16_t blocknum, uint16_t lasernum) {
  auto iscan = blockIdx.x;
  auto ichannel = threadIdx.x;
  if (blocknum == 0 || lasernum == 0) return;
  float apha =  channel_elevations[0];
  float beta =  channel_elevations[1];
  float gamma =  channel_elevations[2];
  float raw_azimuth = raw_azimuths[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))];
  float raw_elevation = raw_elevations[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))];
  float phi = channel_azimuths[(ichannel % lasernum) + 3];
  float theta = channel_elevations[(ichannel % lasernum) + 3];
  float an = apha + phi;
  float theta_n = (raw_elevation + theta / std::cos(an * M_PI / 180));
  float elv_v = raw_elevation * M_PI / 180 + theta * M_PI / 180 - std::tan(raw_elevation * M_PI / 180) * (1 - std::cos(an * M_PI / 180)) ;
  float delt_azi_v = std::sin(an * M_PI / 180) * std::cos(an * M_PI / 180) * theta_n * theta_n / 2  * 1.016 * M_PI / 180 * M_PI / 180;
  float eta = phi + delt_azi_v * 180 / M_PI + beta + raw_azimuth / 2;
  float delt_azi_h = std::sin(eta * M_PI / 180) * std::tan(2 * gamma * M_PI / 180) * std::tan(elv_v ) + std::sin(2 * eta * M_PI / 180) * gamma * gamma * M_PI / 180 * M_PI / 180;
  float elv_h = elv_v * 180 / M_PI + std::cos(eta * M_PI / 180) * 2 * gamma ;
  float azi_h = 90 +  raw_azimuth + delt_azi_h * 180 / M_PI + delt_azi_v * 180 / M_PI + phi;

  auto rho = raw_distances[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))] * raw_distance_unit;
  float z = rho * std::sin(elv_h * M_PI / 180);
  auto r = rho * std::cos(elv_h * M_PI / 180) ;
  float x = r * std::sin(azi_h * M_PI / 180);
  float y = r * std::cos(azi_h * M_PI / 180);

  float cosa = std::cos(transform.roll);
  float sina = std::sin(transform.roll);
  float cosb = std::cos(transform.pitch);
  float sinb = std::sin(transform.pitch);
  float cosc = std::cos(transform.yaw);
  float sinc = std::sin(transform.yaw);

  float x_ = cosb * cosc * x + (sina * sinb * cosc - cosa * sinc) * y +
              (sina * sinc + cosa * sinb * cosc) * z + transform.x;
  float y_ = cosb * sinc * x + (cosa * cosc + sina * sinb * sinc) * y +
              (cosa * sinb * sinc - sina * cosc) * z + transform.y;
  float z_ = -sinb * x + sina * cosb * y + cosa * cosb * z + transform.z;
  gpu::setX(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], x_);
  gpu::setY(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))],  y_);
  gpu::setZ(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], z_);
  gpu::setIntensity(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], raw_reflectivities[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))]);
  gpu::setTimestamp(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], double(raw_sensor_timestamp[iscan]) / kMicrosecondToSecond);
}
template <typename T_Point>
int Udp2_4ParserGpu<T_Point>::ComputeXYZI(LidarDecodedFrame<T_Point> &frame) {
  if (!corrections_loaded_) return int(ReturnCode::CorrectionsUnloaded);          
  cudaSafeCall(cudaMemcpy(raw_azimuths_cu_, frame.azimuth,
                          kMaxPacketNumPerFrame *  kMaxPointsNumPerPacket * sizeof(float), cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);
  cudaSafeCall(cudaMemcpy(raw_elevations_cu_, frame.elevation,
                          kMaxPacketNumPerFrame *  kMaxPointsNumPerPacket * sizeof(float), cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);             
  cudaSafeCall(cudaMemcpy(raw_distances_cu_, frame.distances,
                          kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(uint16_t),
                          cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError); 
  cudaSafeCall(cudaMemcpy(raw_reflectivities_cu_, frame.reflectivities,
                          kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(uint8_t),
                          cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);  
  cudaSafeCall(cudaMemcpy(raw_sensor_timestamp_cu_, frame.sensor_timestamp,
                          kMaxPacketNumPerFrame * sizeof(uint64_t),
                          cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);                                  

compute_xyzs_2_4_impl<<<kMaxPacketNumPerFrame, kMaxPointsNumPerPacket>>>(this->frame_.gpu()->points, channel_azimuths_cu_, channel_elevations_cu_, 
  raw_azimuths_cu_, raw_elevations_cu_, raw_distances_cu_, raw_reflectivities_cu_, raw_sensor_timestamp_cu_, frame.distance_unit, 
  this->transform_, frame.block_num, frame.laser_num);
  cudaSafeCall(cudaGetLastError(), ReturnCode::CudaXYZComputingError);
  this->frame_.DeviceToHost();
  std::memcpy(frame.points, this->frame_.cpu()->points, sizeof(T_Point) * kMaxPacketNumPerFrame * kMaxPointsNumPerPacket);
  return 0;
}
template<typename T_Point>
int Udp2_4ParserGpu<T_Point>::LoadCorrectionString(char *data) {
  if (LoadCorrectionDatData(data) == 0) {
    return 0;
  }
  return LoadCorrectionCsvData(data);
}


// csv ----> correction
template<typename T_Point>
int  Udp2_4ParserGpu<T_Point>::LoadCorrectionCsvData(char *correction_string)
{
  std::ifstream file(correction_string);
  if (!file.is_open()) {
      printf("open the .csv faild\n");
      return 0;
  }
  std::vector<float> column2;
  std::vector<float> column3;
  std::string line;
  std::getline(file, line);
  while (std::getline(file, line)) {
      std::stringstream lineStream(line);
      std::string cell;
      std::vector<std::string> row;
      while (std::getline(lineStream, cell, ',')) {
          row.push_back(cell);
      }
      if (row.size() >= 3) {
          column2.push_back(std::stof(row[1]));
          column3.push_back(std::stof(row[2]));
      }
  }
  file.close();
  corrections_.delimiter[0] = 0xee;
  corrections_.delimiter[1] = 0xff;
  corrections_.major_version = 0x03;
  corrections_.min_version = 0x01;
  corrections_.channel_number = 0x40;
  corrections_.angle_division = 0x01;

  for (size_t i = 0; i < column3.size(); i++) {
    corrections_.elevations[i] = column2[i];
    corrections_.azimuths[i] = column3[i];
  }
  CUDACheck(cudaMalloc(&channel_azimuths_cu_, sizeof(corrections_.azimuths)));
  CUDACheck(cudaMalloc(&channel_elevations_cu_, sizeof(corrections_.elevations)));
  CUDACheck(cudaMemcpy(channel_azimuths_cu_, corrections_.azimuths, sizeof(corrections_.azimuths), cudaMemcpyHostToDevice));
  CUDACheck(cudaMemcpy(channel_elevations_cu_, corrections_.elevations, sizeof(corrections_.elevations), cudaMemcpyHostToDevice));
  corrections_loaded_ = true;
  return 0;
}


// buffer(.bin) ---> correction
template<typename T_Point>
int Udp2_4ParserGpu<T_Point>::LoadCorrectionDatData(char *data) {
  try {
    char *p = data;
    struct ETCorrections_v4_Header ETheader = *((struct ETCorrections_v4_Header* )p);
    if (0xee == ETheader.delimiter[0] && 0xff == ETheader.delimiter[1]) {
      switch (ETheader.min_version) {
        case 1: {
          memcpy((void *)&corrections_, p, sizeof(struct ETCorrections_v4_Header));
          p += sizeof(ETCorrections_v4_Header);
          auto channel_num = corrections_.channel_number;
          uint16_t division = corrections_.angle_division;
          memcpy((void *)&corrections_.raw_azimuths, p,
                 sizeof(int16_t) * channel_num);
          p += sizeof(int16_t) * channel_num;
          memcpy((void *)&corrections_.raw_elevations, p,
                 sizeof(int16_t) * channel_num);
          p += sizeof(int16_t) * channel_num;
          corrections_.elevations[0] = ((float)(corrections_.apha)) / division;
          corrections_.elevations[1] = ((float)(corrections_.beta)) / division;
          corrections_.elevations[2] = ((float)(corrections_.gamma)) / division;
          printf("apha:%f, beta:%f, gamma:%f\n", corrections_.elevations[0], corrections_.elevations[1], corrections_.elevations[2]);
          for (int i = 0; i < channel_num; i++) {
            corrections_.azimuths[i + 3] = ((float)(corrections_.raw_azimuths[i])) / division;
            corrections_.elevations[i + 3] = ((float)(corrections_.raw_elevations[i])) / division;
            printf("%d %f %f \n",i, corrections_.azimuths[i + 3], corrections_.elevations[i + 3]);
          }
          memcpy((void*)&corrections_.SHA_value, p, 32);
          // successed
          CUDACheck(cudaMalloc(&channel_azimuths_cu_, sizeof(corrections_.azimuths)));
          CUDACheck(cudaMalloc(&channel_elevations_cu_, sizeof(corrections_.elevations)));
          CUDACheck(cudaMemcpy(channel_azimuths_cu_, corrections_.azimuths, sizeof(corrections_.azimuths), cudaMemcpyHostToDevice));
          CUDACheck(cudaMemcpy(channel_elevations_cu_, corrections_.elevations, sizeof(corrections_.elevations), cudaMemcpyHostToDevice));
          corrections_loaded_ = true;
          return 0;
        } break;
        default:
          printf("min_version is wrong!\n");
          break;
      }
    } else {
        return -1;
    }
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
  return -1;
}
template <typename T_Point>
int Udp2_4ParserGpu<T_Point>::LoadCorrectionFile(std::string lidar_correction_file) {
  int ret = 0;
  printf("load correction file from local correction.csv now!\n");
  std::ifstream fin(lidar_correction_file);
  if (fin.is_open()) {
    printf("Open correction file success\n");
    int length = 0;
    std::string str_lidar_calibration;
    fin.seekg(0, std::ios::end);
    length = fin.tellg();
    fin.seekg(0, std::ios::beg);
    char *buffer = new char[length];
    fin.read(buffer, length);
    fin.close();
    str_lidar_calibration = buffer;
    ret = LoadCorrectionString(buffer);
    if (ret != 0) {
      printf("Parse local Correction file Error\n");
    } else {
      printf("Parse local Correction file Success!!!\n");
      return 0;
    }
  } else {
    printf("Open correction file failed\n");
    return -1;
  }
  return -1;
}

