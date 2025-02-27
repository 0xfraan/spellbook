{{ config(
    schema = 'woofi_optimism',
    alias = 'trades',
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index'],
    post_hook='{{ expose_spells(\'["optimism"]\',
                                    "project",
                                    "woofi",
                                    \'["ARDev097", "tomfutago"]\') }}'
)
}}
    
{% set project_start_date = '2022-11-23' %}

WITH dexs as 
 (SELECT
            evt_block_time AS block_time
            ,'woofi' AS project
            ,'1' AS version
            ,"from" AS taker
            ,to AS maker
            ,toAmount AS token_bought_amount_raw
            ,fromAmount AS token_sold_amount_raw
            ,NULL AS amount_usd
            ,toToken AS token_bought_address
            ,fromToken AS token_sold_address
            ,contract_address AS project_contract_address
            ,evt_tx_hash AS tx_hash
            ,evt_index
        FROM
            {{ source('woofi_optimism', 'WooPPV2_evt_WooSwap')}}
        WHERE "from" <> 0xeaf1ac8e89ea0ae13e0f03634a4ff23502527024 -- woorouter

        {% if is_incremental() %}
        AND evt_block_time >= date_trunc('day', now() - interval '7' day)
        {% endif %}

        UNION ALL 

        SELECT
            evt_block_time AS block_time
            ,'woofi' AS project
            ,'1' AS version
            ,"from" AS taker
            ,to AS maker
            ,toAmount AS token_bought_amount_raw
            ,fromAmount AS token_sold_amount_raw
            ,NULL AS amount_usd
            ,toToken AS token_bought_address
            ,fromToken AS token_sold_address
            ,contract_address AS project_contract_address
            ,evt_tx_hash AS tx_hash
            ,evt_index
        FROM
            {{ source('woofi_optimism', 'WooRouterV2_evt_WooRouterSwap')}}

        {% if is_incremental() %}
        WHERE evt_block_time >= date_trunc('day', now() - interval '7' day)
        {% endif %}


 )


SELECT
    'optimism' AS blockchain
    ,project
    ,version
    ,TRY_CAST(date_trunc('day', dexs.block_time) AS date) AS block_date
    ,CAST(date_trunc('month', dexs.block_time) AS date) AS block_month
    ,dexs.block_time
    ,erc20a.symbol AS token_bought_symbol
    ,erc20b.symbol AS token_sold_symbol
    ,case
        when lower(erc20a.symbol) > lower(erc20b.symbol) then concat(erc20b.symbol, '-', erc20a.symbol)
        else concat(erc20a.symbol, '-', erc20b.symbol)
    end as token_pair
    ,dexs.token_bought_amount_raw / power(10, erc20a.decimals) AS token_bought_amount
    ,dexs.token_sold_amount_raw / power(10, erc20b.decimals) AS token_sold_amount
    ,dexs.token_bought_amount_raw  AS token_bought_amount_raw
    ,dexs.token_sold_amount_raw  AS token_sold_amount_raw
    ,coalesce(
        dexs.amount_usd
        , (dexs.token_bought_amount_raw
            / power(10, (CASE dexs.token_bought_address
                             WHEN 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee THEN 18
                             ELSE p_bought.decimals
                END))
              )
            * (CASE dexs.token_bought_address
                   WHEN 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee THEN p_op.price
                   ELSE p_bought.price
                END)
        , (dexs.token_sold_amount_raw
            / power(10, (CASE dexs.token_sold_address
                             WHEN 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee THEN 18
                             ELSE p_sold.decimals
                END))
              )
            * (CASE dexs.token_sold_address
                   WHEN 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee THEN p_op.price
                   ELSE p_sold.price
                END)
    ) as amount_usd
    ,dexs.token_bought_address
    ,dexs.token_sold_address
    ,coalesce(dexs.taker, tx."from") AS taker 
    ,dexs.maker
    ,dexs.project_contract_address
    ,dexs.tx_hash
    ,tx."from" AS tx_from
    ,tx.to AS tx_to
    ,dexs.evt_index
FROM dexs
INNER JOIN {{ source('optimism', 'transactions')}} tx
    ON dexs.tx_hash = tx.hash
    {% if not is_incremental() %}
    AND tx.block_time >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND tx.block_time >= date_trunc('day', now() - interval '7' day)
    {% endif %}
LEFT JOIN {{ ref('tokens_erc20') }} erc20a
    ON erc20a.contract_address = dexs.token_bought_address
    AND erc20a.blockchain = 'optimism'
LEFT JOIN {{ ref('tokens_erc20') }} erc20b
    ON erc20b.contract_address = dexs.token_sold_address
    AND erc20b.blockchain = 'optimism'
LEFT JOIN {{ source('prices', 'usd') }} p_bought
    ON p_bought.minute = date_trunc('minute', dexs.block_time)
    AND p_bought.contract_address = dexs.token_bought_address
    AND p_bought.blockchain = 'optimism'
    {% if not is_incremental() %}
    AND p_bought.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_bought.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', dexs.block_time)
    AND p_sold.contract_address = dexs.token_sold_address
    AND p_sold.blockchain = 'optimism'
    {% if not is_incremental() %}
    AND p_sold.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_sold.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_op
    ON p_op.minute = date_trunc('minute', dexs.block_time)
    AND p_op.blockchain is null
    AND p_op.symbol = 'OP'
    {% if not is_incremental() %}
    AND p_op.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_op.minute >= date_trunc('day', now() - interval '7' day)
    {% endif %}
