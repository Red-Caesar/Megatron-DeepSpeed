#!/bin/bash
# This example script is contributed by external user https://github.com/LydiaXiaohongLi
set -ex

######################################
# Change the below configurations here
uv pip install sentencepiece setuptools einops deepspeed transformers pybind11 nltk ipython matplotlib
BASE_PATH=`pwd`
if [ ! -f "${BASE_PATH}/oscar-1GB.jsonl" ]; then
  wget https://huggingface.co/bigscience/misc-test-data/resolve/main/stas/oscar-1GB.jsonl.xz
  xz -d oscar-1GB.jsonl.xz
fi
if [ ! -f "${BASE_PATH}/tokenizer.model" ]; then
  wget https://huggingface.co/NousResearch/Llama-2-7b-hf/resolve/main/tokenizer.model #download tokenizer.model
fi

TOKENIZER_PATH="${BASE_PATH}/tokenizer.model" # offical llama tokenizer.model

if [ ! -f "${BASE_PATH}/my-llama_text_document.bin" ]; then
python3 ${BASE_PATH}/tools/preprocess_data.py --input ${BASE_PATH}/oscar-1GB.jsonl \
  --output-prefix ${BASE_PATH}/my-llama \
  --dataset-impl mmap \
  --tokenizer-type GPTSentencePieceTokenizer \
  --append-eod \
  --workers 8 \
  --tokenizer-model $TOKENIZER_PATH
fi

DS_CONFIG="${BASE_PATH}/deepspeed.json"
DATASET="${BASE_PATH}/my-llama_text_document"
CHECKPOINT_PATH="${BASE_PATH}/checkpoint/"
mkdir -p checkpoint


TP=2
PP=2
ZERO_STAGE=0

GPUS_PER_NODE=1
MASTER_ADDR=localhost
MASTER_PORT=6000
NNODES=1
NODE_RANK=0

HIDDEN_SIZE=2048 # e.g. llama-13b: 5120
FFN_HIDDEN_SIZE=5504 # e.g. llama-13b: 13824
NUM_LAYERS=24 # e.g. llama-13b: 40
NUM_HEADS=16 # e.g. llama-13b: 40
SEQ_LENGTH=2048

MICRO_BATCH_SIZE=4
GLOBAL_BATCH_SIZE=16 # e.g. llama: 4M tokens
TRAIN_STEPS=32 # e.g. llama: 1T tokens / 4M tokens_per_batch = 250000 steps
LR=3e-4
MIN_LR=3e-5
LR_WARMUP_STEPS=16
WEIGHT_DECAY=0.1
GRAD_CLIP=1

## Activation checkpointing saves GPU memory, but reduces training speed
# activation_checkpoint="true"
activation_checkpoint="false"

# Below configuration required for llama model as per llama paper
# --no-query-key-layer-scaling \
# --attention-dropout 0 \
# --hidden-dropout 0 \
# --use-rotary-position-embeddings \
# --untie-embeddings-and-output-weights \
# --swiglu \
# --normalization rmsnorm \
# --disable-bias-linear \
####################################



cat <<EOT > $DS_CONFIG
{
  "train_batch_size" : $GLOBAL_BATCH_SIZE,
  "train_micro_batch_size_per_gpu": $MICRO_BATCH_SIZE,
  "steps_per_print": 1,
  "zero_optimization": {
    "stage": $ZERO_STAGE
  },
  "bf16": {
    "enabled": true
  }
}
EOT

ds_args=""
ds_args=" --deepspeed ${ds_args}"
ds_args=" --deepspeed_config=$DS_CONFIG ${ds_args}"
ds_args=" --zero-stage=$ZERO_STAGE ${ds_args}"

if [ "${activation_checkpoint}" = "true" ]; then
  ds_args="--deepspeed-activation-checkpointing ${ds_args}"

  ## old argument for recomputing the transformer layer
  # ds_args="--checkpoint-activations ${ds_args}"

  ## new argument for recomputing the transformer layer
  ds_args="--recompute-granularity full --recompute-method uniform ${ds_args}"
  ## new argument for recomputing only the attention layer
  # ds_args="--recompute-granularity selective ${ds_args}"
fi

DISTRIBUTED_ARGS="--nproc_per_node $GPUS_PER_NODE --nnodes $NNODES --node_rank $NODE_RANK --master_addr $MASTER_ADDR --master_port $MASTER_PORT"

torchrun $DISTRIBUTED_ARGS \
       pretrain_gpt.py \
       --tensor-model-parallel-size $TP \
       --pipeline-model-parallel-size $PP \
       --num-layers $NUM_LAYERS \
       --hidden-size $HIDDEN_SIZE \
       --ffn-hidden-size $FFN_HIDDEN_SIZE \
       --num-attention-heads $NUM_HEADS \
       --micro-batch-size $MICRO_BATCH_SIZE \
       --global-batch-size $GLOBAL_BATCH_SIZE \
       --seq-length $SEQ_LENGTH \
       --max-position-embeddings $SEQ_LENGTH \
       --train-iters $TRAIN_STEPS \
       --save $CHECKPOINT_PATH \
       --load $CHECKPOINT_PATH \
       --data-path $DATASET \
       --data-impl mmap \
       --tokenizer-type GPTSentencePieceTokenizer \
       --tokenizer-model $TOKENIZER_PATH \
       --split 949,50,1 \
       --distributed-backend nccl \
       --lr $LR \
       --lr-decay-style cosine \
       --min-lr $MIN_LR \
       --weight-decay $WEIGHT_DECAY \
       --clip-grad $GRAD_CLIP \
       --lr-warmup-iters $LR_WARMUP_STEPS \
       --optimizer adam \
       --adam-beta1 0.9 \
       --adam-beta2 0.95 \
       --log-interval 1 \
       --save-interval 10000 \
       --eval-interval 1000 \
       --eval-iters 10 \
       --bf16 \
       --no-query-key-layer-scaling \
       --attention-dropout 0 \
       --hidden-dropout 0 \
       --use-rotary-position-embeddings \
       --untie-embeddings-and-output-weights \
       --swiglu \
       --normalization rmsnorm \
       --disable-bias-linear \
       $ds_args