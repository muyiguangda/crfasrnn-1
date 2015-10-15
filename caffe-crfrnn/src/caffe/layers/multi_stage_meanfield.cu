/*!
 *  \brief     The Caffe layer that implements the CRF-RNN described in the paper:
 *             Conditional Random Fields as Recurrent Neural Networks. IEEE ICCV 2015.
 *
 *  \authors   Sadeep Jayasumana, Bernardino Romera-Paredes, Shuai Zheng, Zhizhong Su.
 *  \version   1.0
 *  \date      2015
 *  \copyright Torr Vision Group, University of Oxford.
 *  \details   If you use this code, please consider citing the paper:
 *             Shuai Zheng, Sadeep Jayasumana, Bernardino Romera-Paredes, Vibhav Vineet, Zhizhong Su, Dalong Du,
 *             Chang Huang, Philip H. S. Torr. Conditional Random Fields as Recurrent Neural Networks. IEEE ICCV 2015.
 *
 *             For more information about CRF-RNN, please visit the project website http://crfasrnn.torr.vision.
 */
#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layer.hpp"
#include "caffe/util/im2col.hpp"
#include "caffe/vision_layers.hpp"

namespace caffe {
  
template <typename Dtype>
__global__ void  computeBilateralKernel(const  int num_pixels_, 
    const Dtype* const rgb_blob, 
    const int width_, const int height_, const int channels_,
    float theta_alpha_, float theta_beta_,
    const int n, float* const output_kernel) {
  int offset = ((n * channels_ ) * height_) * width_ ;
  CUDA_KERNEL_LOOP(p, num_pixels_) {
    output_kernel[5 * p] = (float)(p % width_) / theta_alpha_;
    output_kernel[5 * p + 1] = (float)(p / width_) / theta_alpha_;
    const Dtype * const rgb_data_start = rgb_blob + offset;
    output_kernel[5 * p + 2] = (float)(rgb_data_start[p] / theta_beta_);
    output_kernel[5 * p + 3] = (float)((rgb_data_start + num_pixels_)[p] / theta_beta_);
    output_kernel[5 * p + 4] = (float)((rgb_data_start + num_pixels_ * 2)[p] / theta_beta_);
  }
}

template <typename Dtype>
__global__ void  computeSpatialKernel(const int num_pixels_,
    float* const output_kernel,
    float theta_gamma_, int width_) {
  CUDA_KERNEL_LOOP(p, num_pixels_) {
    output_kernel[2*p] = (float)(p % width_) / theta_gamma_;
    output_kernel[2*p + 1] = (float)(p / width_) / theta_gamma_;
  }
}

// TODO : can't be defined here
template <typename Dtype>
void MultiStageMeanfieldLayer<Dtype>::LayerSetUp(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {

  const caffe::MultiStageMeanfieldParameter meanfield_param = this->layer_param_.multi_stage_meanfield_param();

  num_iterations_ = meanfield_param.num_iterations();

  CHECK_GT(num_iterations_, 1) << "Number of iterations must be greater than 1.";

  theta_alpha_ = meanfield_param.theta_alpha();
  theta_beta_ = meanfield_param.theta_beta();
  theta_gamma_ = meanfield_param.theta_gamma();

  count_ = bottom[0]->count();
  num_ = bottom[0]->num();
  channels_ = bottom[0]->channels();
  height_ = bottom[0]->height();
  width_ = bottom[0]->width();
  num_pixels_ = height_ * width_;

  LOG(INFO) << "This implementation has not been tested batch size > 1.";

  top[0]->Reshape(num_, channels_, height_, width_);

  // Initialize the parameters that will updated by backpropagation.
  if (this->blobs_.size() > 0) {
    LOG(INFO) << "Multimeanfield layer skipping parameter initialization.";
  } else {

    this->blobs_.resize(3);// blobs_[0] - spatial kernel weights, blobs_[1] - bilateral kernel weights, blobs_[2] - compatability matrix

    // Allocate space for kernel weights.
    this->blobs_[0].reset(new Blob<Dtype>(1, 1, channels_, channels_));
    this->blobs_[1].reset(new Blob<Dtype>(1, 1, channels_, channels_));

    caffe_set(channels_ * channels_, Dtype(0.), this->blobs_[0]->mutable_cpu_data());
    caffe_set(channels_ * channels_, Dtype(0.), this->blobs_[1]->mutable_cpu_data());

    // Initialize the kernels weights. The two files spatial.par and bilateral.par should be available.
    FILE * pFile;
    pFile = fopen("spatial.par", "r");
    CHECK(pFile) << "The file 'spatial.par' is not found. Please create it with initial spatial kernel weights.";
    for (int i = 0; i < channels_; i++) {
      fscanf(pFile, "%lf", &this->blobs_[0]->mutable_cpu_data()[i * channels_ + i]);
    }
    fclose(pFile);

    //TODO : check if we can give it directly to the GPU
    this->blobs_[0]->mutable_gpu_data ;

    pFile = fopen("bilateral.par", "r");
    CHECK(pFile) << "The file 'bilateral.par' is not found. Please create it with initial bilateral kernel weights.";
    for (int i = 0; i < channels_; i++) {
      fscanf(pFile, "%lf", &this->blobs_[1]->mutable_cpu_data()[i * channels_ + i]);
    }
    fclose(pFile);

    //TODO : same here
    this->blobs_[1]->mutable_gpu_data ;
    
    // Initialize the compatibility matrix.
    this->blobs_[2].reset(new Blob<Dtype>(1, 1, channels_, channels_));
    caffe_set(channels_ * channels_, Dtype(0.), this->blobs_[2]->mutable_cpu_data());

    // Initialize it to have the Potts model.
    // TODO : kernel here ?
    for (int c = 0; c < channels_; ++c) {
      (this->blobs_[2]->mutable_cpu_data())[c * channels_ + c] = Dtype(-1.);
    }
  }

  this->blobs_[2]->mutable_gpu_data() ;
  
  // Initialize the spatial lattice. This does not need to be computed for every image because we use a fixed size.
  float spatial_kernel[2 * num_pixels_];
  compute_spatial_kernel(spatial_kernel);
  spatial_lattice_.reset(new ModifiedPermutohedral());
  spatial_lattice_->init(spatial_kernel, 2, num_pixels_);

  // Calculate spatial filter normalization factors.
  norm_feed_.reset(new Dtype[num_pixels_]);
  caffe_set(num_pixels_, Dtype(1.0), norm_feed_.get());
  spatial_norm_.Reshape(1, 1, height_, width_);
  Dtype* norm_data = spatial_norm_.mutable_cpu_data();
  spatial_lattice_->compute(norm_data, norm_feed_.get(), 1);
  for (int i = 0; i < num_pixels_; ++i) {
    norm_data[i] = 1.0f / (norm_data[i] + 1e-20f);
  }

  // Allocate space for bilateral kernels. This is a temporary buffer used to compute bilateral lattices later.
  // Also allocate space for holding bilateral filter normalization values.
  bilateral_kernel_buffer_.reset(new float[5 * num_pixels_]);
  bilateral_norms_.Reshape(num_, 1, height_, width_);

  // Configure the split layer that is used to make copies of the unary term. One copy for each iteration.
  // It may be possible to optimize this calculation later.
  split_layer_bottom_vec_.clear();
  split_layer_bottom_vec_.push_back(bottom[0]);

  split_layer_top_vec_.clear();

  split_layer_out_blobs_.resize(num_iterations_);
  for (int i = 0; i < num_iterations_; i++) {
    split_layer_out_blobs_[i].reset(new Blob<Dtype>());
    split_layer_top_vec_.push_back(split_layer_out_blobs_[i].get());
  }

  LayerParameter split_layer_param;
  split_layer_.reset(new SplitLayer<Dtype>(split_layer_param));
  split_layer_->SetUp(split_layer_bottom_vec_, split_layer_top_vec_);

  // Make blobs to store outputs of each meanfield iteration. Output of the last iteration is stored in top[0].
  // So we need only (num_iterations_ - 1) blobs.
  iteration_output_blobs_.resize(num_iterations_ - 1);
  for (int i = 0; i < num_iterations_ - 1; ++i) {
    iteration_output_blobs_[i].reset(new Blob<Dtype>(num_, channels_, height_, width_));
  }

  // Make instances of MeanfieldIteration and initialize them.
  //TODO OneTimeSetup for GPU ?
  meanfield_iterations_.resize(num_iterations_);
  for (int i = 0; i < num_iterations_; ++i) {
    meanfield_iterations_[i].reset(new MeanfieldIteration<Dtype>());
    meanfield_iterations_[i]->OneTimeSetUp(
        split_layer_out_blobs_[i].get(), // unary terms
        (i == 0) ? bottom[1] : iteration_output_blobs_[i - 1].get(), // softmax input
        (i == num_iterations_ - 1) ? top[0] : iteration_output_blobs_[i].get(), // output blob
        spatial_lattice_, // spatial lattice
        &spatial_norm_); // spatial normalization factors.
  }

  this->param_propagate_down_.resize(this->blobs_.size(), true);

  LOG(INFO) << ("MultiStageMeanfieldLayer initialized.");
}

template <typename Dtype>
void MultiStageMeanfieldLayer<Dtype>::Reshape(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {
	// Do nothing.
}


/**
 * Performs filter-based mean field inference given the image and unaries.
 *
 * bottom[0] - Unary terms
 * bottom[1] - Softmax input/Output from the previous iteration (a copy of the unary terms if this is the first stage).
 * bottom[2] - RGB images
 *
 * top[0] - Output of the mean field inference (not normalized).
 */
template <typename Dtype>
void MultiStageMeanfieldLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {

  const Dtype* bottom_data = bottom->gpu_data() ;
  // TODO is it suppose to be constant ?
  split_layer_bottom_vec_[0] = bottom[0]->mutable_gpu_data();
  split_layer_->Forward(split_layer_bottom_vec_, split_layer_top_vec_);

  // Initialize the bilateral lattices.
  // TODO : here ?
  bilateral_lattices_.resize(num_);
  for (int n = 0; n < num_; ++n) {
    // TODO get method for permuthohedral
    computeBilateralKernel<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        num_pixels_, bottom_data, width_, height_, channels_,
        theta_alpha_, theta_beta_, n,
         bilateral_kernel_buffer_.get());
    //TODO reset on GPUs ? init on GPU as well
    bilateral_lattices_[n].reset(new ModifiedPermutohedral());
    bilateral_lattices_[n]->init(bilateral_kernel_buffer_.get(), 5, num_pixels_);

    // Calculate bilateral filter normalization factors.
    // is it efficient ? yes
    Dtype* norm_output_data = bilateral_norms_.mutable_gpu_data() + bilateral_norms_.offset(n);
    // TODO compute 
    bilateral_lattices_[n]->compute(norm_output_data, norm_feed_.get(), 1);
    // TODO : do that on the GPU
    for (int i = 0; i < num_pixels_; ++i) {
      norm_output_data[i] = 1.f / (norm_output_data[i] + 1e-20f);
    }
  }

  for (int i = 0; i < num_iterations_; ++i) {
    //TODO : GPU
    meanfield_iterations_[i]->PrePass(this->blobs_, &bilateral_lattices_, &bilateral_norms_);

    meanfield_iterations_[i]->Forward_gpu();
  }
}

/**
 * Backprop through filter-based mean field inference.
 */
template<typename Dtype>
void MultiStageMeanfieldLayer<Dtype>::Backward_cpu(
    const vector<Blob<Dtype>*>& top, const vector<bool>& propagate_down,
    const vector<Blob<Dtype>*>& bottom) {

  for (int i = (num_iterations_ - 1); i >= 0; --i) {
    meanfield_iterations_[i]->Backward_cpu();
  }

  vector<bool> split_layer_propagate_down(1, true);
  split_layer_->Backward(split_layer_top_vec_, split_layer_propagate_down, split_layer_bottom_vec_);

  // Accumulate diffs from mean field iterations.
  for (int blob_id = 0; blob_id < this->blobs_.size(); ++blob_id) {

    Blob<Dtype>* cur_blob = this->blobs_[blob_id].get();

    if (this->param_propagate_down_[blob_id]) {

      caffe_set(cur_blob->count(), Dtype(0), cur_blob->mutable_cpu_diff());

      for (int i = 0; i < num_iterations_; ++i) {
        const Dtype* diffs_to_add = meanfield_iterations_[i]->blobs()[blob_id]->cpu_diff();
        caffe_axpy(cur_blob->count(), Dtype(1.), diffs_to_add, cur_blob->mutable_cpu_diff());
      }
    }
  }
}



INSTANTIATE_LAYER_GPU_FUNCS(MultiStageMeanfieldLayer);

}  // namespace caffe
