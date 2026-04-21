1. what model to use for local training
- light vs. large? most local model cannot do tool calling
- some model only have specific functions, such as it can only call tools
 - or it can only use some tool, cannot chat
 - pick one that's suitable for my project/use case

- gpt 5.2 fast vs. thinking vs. reasoning:
    - each has their own difference
    - thinking model has chain of thoughts --> need to add chain of thoughts in your local model training data
    - chain of thoughts: ** how to prepare this?


(1) Q & A
(2) chain of thoughts
 - model cannot think more than what current callable tool
 - these are added to the Q & A

(3) tool calling
 - single vs. multiple
 - tool calling with chain of thoughts
 - Q & A: add thinking on tool calling; give example on if fail, do some steps to make sure it can be sucessful; able to make self correct 
    - add some error cases, so the model can fix itself
    - negative cases
1. data gathering (phagocyte: everything done by agent --> use it to gather data (use v2))
- processor: the last module is required, it chunks and embedding.
    - don't do embedding (take forever)
    - for Q&A generating, use only chunks
2. Q & A generation (Generator: in Shazzadul's private github )
- 50000 data, synthetic QA generation.
 - will hit usage limit do it blindly
 - need to give many context to generate the data
 
3. training/finetuning (unsloth)
- once all QA and datasets are ready, upload the data to codelab and run