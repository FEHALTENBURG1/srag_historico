#!/usr/bin/env Rscript
# =============================================================================
# 03_prepara.R  —  Preparo analítico da base SRAG / RIDE-DF
# -----------------------------------------------------------------------------
# Roda no GitHub Actions (segundas e terças). Lê os recortes da RIDE por ano
# (data/historico/bruto/*.parquet, gerados pelos passos 01/02) e aplica TODAS as
# derivações que antes viviam dentro do app.R (vírus, faixa etária, território,
# Região Administrativa, gargalo, atrasos, denominadores por linha, etc.).
#
# Saídas:
#   data/historico/pronto/srag_ride_pronto_<AAAA>.parquet  — série histórica,
#       um arquivo por ano. Só é refeito o ano cujo recorte mudou (ou todos,
#       quando este script muda), então os anos congelados não geram commit.
#   data/historico/serie_semanal.csv  — casos/óbitos/UTI por SE (2019 em diante)
#   data/srag_ride_pronto.csv  — SÓ o ano mais recente, como sempre foi.
#       O app.R atual continua lendo esse arquivo sem nenhuma mudança.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(lubridate)
  library(readr)
  library(duckdb)
  library(DBI)
})

source("R/config.R")   # caminhos da série histórica e manifesto

drv <- duckdb::duckdb()   # manter o driver numa variável (ver 02_filter_clean.R)
con <- dbConnect(drv)

# -----------------------------------------------------------------------------
# 1. TABELAS DE REFERÊNCIA
# -----------------------------------------------------------------------------
ride_df_ref <- tibble::tribble(
  ~codigo_municipio, ~municipio_ride,                   ~uf_ride, ~populacao,
  530010,            "Distrito Federal",                "DF",     2996899,
  520010,            "Abadiânia",                       "GO",       22000,
  520017,            "Água Fria de Goiás",              "GO",        5500,
  520025,            "Águas Lindas de Goiás",           "GO",      220000,
  520030,            "Alexânia",                        "GO",       32000,
  520060,            "Alto Paraíso de Goiás",           "GO",        9000,
  520080,            "Alvorada do Norte",               "GO",        6000,
  520320,            "Barro Alto",                      "GO",       14000,
  520400,            "Cabeceiras",                      "GO",        8000,
  520530,            "Cavalcante",                      "GO",       10000,
  520549,            "Cidade Ocidental",                "GO",      110000,
  520551,            "Cocalzinho de Goiás",             "GO",       22000,
  520580,            "Corumbá de Goiás",                "GO",       11000,
  520620,            "Cristalina",                      "GO",       62000,
  520790,            "Flores de Goiás",                 "GO",        8000,
  520800,            "Formosa",                         "GO",      130000,
  520860,            "Goianésia",                       "GO",       80000,
  521250,            "Luziânia",                        "GO",      220000,
  521305,            "Mimoso de Goiás",                 "GO",        3000,
  521460,            "Niquelândia",                     "GO",       45000,
  521523,            "Novo Gama",                       "GO",      130000,
  521560,            "Padre Bernardo",                  "GO",       32000,
  521730,            "Pirenópolis",                     "GO",       28000,
  521760,            "Planaltina",                      "GO",       92000,
  521975,            "Santo Antônio do Descoberto",     "GO",       92000,
  522000,            "São João d'Aliança",              "GO",       11000,
  522068,            "Simolândia",                      "GO",        7000,
  522185,            "Valparaíso de Goiás",             "GO",      185000,
  522220,            "Vila Boa",                        "GO",        4000,
  522230,            "Vila Propício",                   "GO",        6000,
  310450,            "Arinos",                          "MG",       17586,
  310930,            "Buritis",                         "MG",       24779,
  310945,            "Cabeceira Grande",                "MG",        6811,
  317040,            "Unaí",                            "MG",       91320
)
codigos_ride <- ride_df_ref$codigo_municipio

ra_df_ref <- tibble::tribble(
  ~numero, ~regiao_administrativa,     ~populacao,
  "I",     "Plano Piloto",              207996,
  "II",    "Gama",                      133948,
  "III",   "Taguatinga",                201332,
  "IV",    "Brazlândia",                 41859,
  "V",     "Sobradinho",                 70608,
  "VI",    "Planaltina",                121856,
  "VII",   "Paranoá",                    55551,
  "VIII",  "Núcleo Bandeirante",         22566,
  "IX",    "Ceilândia",                 287113,
  "X",     "Guará",                     127952,
  "XI",    "Cruzeiro",                   26435,
  "XII",   "Samambaia",                 227118,
  "XIII",  "Santa Maria",               121635,
  "XIV",   "São Sebastião",              99050,
  "XV",    "Recanto das Emas",          105862,
  "XVI",   "Lago Sul",                   27213,
  "XVII",  "Riacho Fundo",               41040,
  "XVIII", "Lago Norte",                 43817,
  "XIX",   "Candangolândia",             14540,
  "XX",    "Águas Claras",              141872,
  "XXI",   "Riacho Fundo II",            70180,
  "XXII",  "Sudoeste/Octogonal",         46004,
  "XXIII", "Varjão",                      9017,
  "XXIV",  "Park Way",                   22667,
  "XXV",   "SCIA",                       38047,
  "XXVI",  "Sobradinho II",              79932,
  "XXVII", "Jardim Botânico",            75133,
  "XXVIII","Itapoã",                     67021,
  "XXIX",  "SIA",                         5630,
  "XXX",   "Vicente Pires",             105062,
  "XXXI",  "Fercal",                      9141,
  "XXXII", "Sol Nascente/Pôr do Sol",   108713,
  "XXXIII","Arniqueira",                 44774,
  "XXXIV", "Arapoanga",                  49067,
  "XXXV",  "Água Quente",                11306
)

# --- Normalização de Região Administrativa (residência no DF) ----------------
chave_ra <- function(x) {
  x <- toupper(as.character(x))
  x <- iconv(x, to = "ASCII//TRANSLIT")
  x <- gsub("REGIAO ADMINISTRATIVA|\\bRA\\b", " ", x)
  x <- gsub("[^A-Z0-9]+", " ", x)
  trimws(gsub("\\s+", " ", x))
}
ra_aliases <- c(
  "BRASILIA"="", "DISTRITO FEDERAL"="", "DF"="",
  "ESTRUTURAL"="SCIA", "CIDADE ESTRUTURAL"="SCIA", "SCIA ESTRUTURAL"="SCIA",
  "SETOR COMPLEMENTAR DE INDUSTRIA E ABASTECIMENTO"="SCIA",
  "SETOR DE INDUSTRIA E ABASTECIMENTO"="SIA",
  "SOL NASCENTE"="Sol Nascente/Pôr do Sol", "POR DO SOL"="Sol Nascente/Pôr do Sol",
  "SOL NASCENTE E POR DO SOL"="Sol Nascente/Pôr do Sol",
  "SUDOESTE"="Sudoeste/Octogonal", "OCTOGONAL"="Sudoeste/Octogonal",
  "SUDOESTE E OCTOGONAL"="Sudoeste/Octogonal",
  "NUCLEO BANDEIRANTE"="Núcleo Bandeirante", "JARDIM BOTANICO"="Jardim Botânico",
  "VICENTE PIRES"="Vicente Pires", "RECANTO DAS EMAS"="Recanto das Emas",
  "AGUAS CLARAS"="Águas Claras", "SAO SEBASTIAO"="São Sebastião"
)
ra_lookup <- tibble::tibble(
  chave = chave_ra(ra_df_ref$regiao_administrativa),
  ra    = ra_df_ref$regiao_administrativa
)
normalizar_ra <- function(x) {
  k   <- chave_ra(x)
  out <- ra_lookup$ra[match(k, ra_lookup$chave)]
  em_alias <- k %in% names(ra_aliases)
  alias_val <- unname(ra_aliases[k[em_alias]])
  alias_val[alias_val == ""] <- NA_character_
  out[em_alias] <- alias_val
  out
}

# -----------------------------------------------------------------------------
# 2. HELPERS DE CONVERSÃO
# -----------------------------------------------------------------------------
normalizar_texto <- function(x) {
  x <- as.character(x); x <- str_squish(x); x[x == ""] <- NA_character_; x
}
converter_numero <- function(x) suppressWarnings(as.numeric(as.character(x)))

# Detecção viral vetorizada (código 1 = Sim). NA vira FALSE.
pos <- function(x) { v <- converter_numero(x); !is.na(v) & v == 1 }

converter_data <- function(x) {
  x <- as.character(x)
  res <- as.Date(rep(NA_real_, length(x)), origin = "1970-01-01")
  # 1) ISO com T e Z:  2026-04-04T00:00:00.000Z
  iso_tz <- suppressWarnings(as_date(as_datetime(x, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")))
  f <- is.na(res); res[f] <- iso_tz[f]
  # 2) Data + hora com ESPAÇO (formato do parquet/DuckDB):  2026-05-04 00:00:00
  f <- is.na(res)
  if (any(f)) res[f] <- suppressWarnings(as_date(ymd_hms(x[f], quiet = TRUE)))
  # 3) ISO simples:  2026-05-04
  f <- is.na(res); if (any(f)) res[f] <- suppressWarnings(ymd(x[f], quiet = TRUE))
  # 4) Brasileiro:    04/05/2026
  f <- is.na(res); if (any(f)) res[f] <- suppressWarnings(dmy(x[f], quiet = TRUE))
  as.Date(res, origin = "1970-01-01")
}

classificar_unidade <- function(nome) {
  n <- str_to_upper(str_squish(as.character(nome)))
  dplyr::case_when(
    is.na(n) | n == "" ~ "Ignorada",
    str_detect(n, "\\bUPA\\b|PRONTO.?ATEND|PRONTO.?SOCORRO") ~ "UPA / Pronto-atendimento",
    str_detect(n, "\\bUBS\\b|\\bAPS\\b|POSTO.?DE.?SAUDE|UNID.*BASICA|POLICLINICA|\\bCAPS\\b|CENTRO.?DE.?SAUDE") ~ "APS / UBS",
    str_detect(n, "HOSPITAL|MATERNO|INSTITUTO|CLINICA|ONCO|SARAH|UNIMED|DAHER|STAR|\\bBASE\\b|\\bSANTA\\b|\\bSAO\\b|\\bHR[A-Z]{1,3}\\b|\\bHFA\\b|\\bHUB\\b|\\bHMIB\\b|\\bHCB\\b|BRASILIA IV") ~ "Hospital",
    TRUE ~ "Outro / não classificado"
  )
}

# =============================================================================
# preparar_base(): seções 3 a 5 aplicadas a UM arquivo de entrada.
#   ENTRADA     recorte da RIDE em parquet (gerado pelo 02_filter_clean.R)
#   id_inicial  deslocamento do id_caso. Na série histórica usamos ano * 1e6
#               (ex.: 2021000001) para o id não se repetir entre os anos.
# =============================================================================
# Colunas que as derivações realmente usam. O recorte tem 194; ler só estas
# (o parquet é colunar) corta a maior parte do tempo de leitura e de memória.
colunas_obrigatorias <- c("CO_MUN_NOT","CO_MUN_RES","SG_UF_NOT","SG_UF","DT_NOTIFIC",
                          "DT_SIN_PRI","SEM_PRI","SEM_NOT")
colunas_opcionais <- c(
  "NU_NOTIFIC","ID_MUNICIP","ID_MN_RESI","NM_UN_INTE","CS_SEXO","TP_IDADE","NU_IDADE_N",
  "CS_RACA","DT_INTERNA","DT_EVOLUCA","UTI","SUPORT_VEN","EVOLUCAO","CLASSI_FIN","PCR_RESUL",
  "RES_AN","ANTIVIRAL","VACINA","CARDIOPATI","DIABETES","OBESIDADE","IMUNODEPRE","RENAL",
  "NEUROLOGIC","PNEUMOPATI","ASMA","POS_PCRFLU","TP_FLU_PCR","POS_AN_FLU","TP_FLU_AN",
  "PCR_VSR","PCR_PARA1","PCR_PARA2","PCR_PARA3","PCR_PARA4","PCR_ADENO","PCR_METAP","PCR_BOCA",
  "PCR_RINO","PCR_SARS2","PCR_OUTRO","AN_SARS2","AN_VSR","AN_PARA1","AN_PARA2","AN_PARA3",
  "AN_ADENO","AN_OUTRO","NM_BAIRRO"
)

preparar_base <- function(ENTRADA, id_inicial = 0L) {
# -----------------------------------------------------------------------------
# 3. LEITURA (tudo como texto: as regras abaixo convertem cada campo)
# -----------------------------------------------------------------------------
cat("Lendo", ENTRADA, "...\n")
existentes <- dbGetQuery(con, sprintf(
  "SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet('%s'))", ENTRADA))$column_name
faltando <- setdiff(colunas_obrigatorias, toupper(existentes))
if (length(faltando) > 0)
  stop("Colunas obrigatórias ausentes em ", ENTRADA, ": ", paste(faltando, collapse = ", "))
usar <- existentes[toupper(existentes) %in% c(colunas_obrigatorias, colunas_opcionais)]

base <- tibble::as_tibble(dbGetQuery(con, sprintf(
  "SELECT %s FROM read_parquet('%s')",
  paste(sprintf('CAST("%s" AS VARCHAR) AS "%s"', usar, toupper(usar)), collapse = ", "),
  ENTRADA)))
# Mesmo tratamento que a leitura por CSV dava: apara espaços e trata vazios como NA.
base[] <- lapply(base, function(x) {
  x <- trimws(x); x[x %in% c("", "NA", "N/A", "NULL")] <- NA_character_; x
})
cat("Linhas lidas:", nrow(base), "\n")

# Garante colunas opcionais ausentes
for (col in setdiff(colunas_opcionais, names(base))) base[[col]] <- NA_character_

# -----------------------------------------------------------------------------
# 4. DERIVAÇÕES
# -----------------------------------------------------------------------------
ref_notificacao <- ride_df_ref %>%
  transmute(CO_MUN_NOT = codigo_municipio,
            municipio_notificacao = municipio_ride, uf_notificacao_ride = uf_ride)
ref_residencia <- ride_df_ref %>%
  transmute(CO_MUN_RES = codigo_municipio,
            municipio_residencia_ride = municipio_ride, uf_residencia_ride = uf_ride,
            populacao_residencia = populacao)

base <- base %>%
  mutate(
    CO_MUN_NOT = converter_numero(CO_MUN_NOT),
    CO_MUN_RES = converter_numero(CO_MUN_RES),
    SG_UF_NOT  = str_to_upper(normalizar_texto(SG_UF_NOT)),
    SG_UF      = str_to_upper(normalizar_texto(SG_UF)),
    ID_MUNICIP = normalizar_texto(ID_MUNICIP),
    ID_MN_RESI = normalizar_texto(ID_MN_RESI)
  ) %>%
  # Mantém o mesmo critério abrangente do 02_filter_clean.R (notificação OU
  # residência na RIDE). O 02 já filtrou; este filtro é só uma salvaguarda e
  # NÃO deve excluir residentes da RIDE notificados fora dela.
  filter(CO_MUN_NOT %in% codigos_ride | CO_MUN_RES %in% codigos_ride) %>%
  left_join(ref_notificacao, by = "CO_MUN_NOT") %>%
  left_join(ref_residencia,  by = "CO_MUN_RES") %>%
  mutate(
    id_caso = as.integer(id_inicial) + row_number(),
    data_notificacao     = converter_data(DT_NOTIFIC),
    data_inicio_sintomas = converter_data(DT_SIN_PRI),
    data_internacao      = converter_data(DT_INTERNA),
    data_evolucao        = converter_data(DT_EVOLUCA),
    # Semana epidemiológica pelo calendário oficial (domingo a sábado; a SE 01
    # é a que tem mais dias em janeiro) -- é o que epiweek()/epiyear() calculam.
    # Calculada a partir da DATA dos primeiros sintomas, e não do campo SEM_PRI,
    # porque o SEM_PRI do Sivep diverge do calendário na virada 2025/2026:
    # marca 28/12/2025-03/01/2026 como SE 01 (o oficial é SE 53/2025) e deixa
    # 2026 inteiro uma semana adiantado (04-10/01/2026 sai SE 02; o oficial é
    # SE 01). SEM_PRI/SEM_NOT ficam só como reserva para registros sem data.
    # (O isoyear() usado antes começa a semana na segunda e rotulava o domingo
    # da virada no ano errado, ex.: 29/12/2024 saía "2024-SE01".)
    semana_epidemiologica = coalesce(as.integer(epiweek(data_inicio_sintomas)),
                                     as.integer(converter_numero(SEM_PRI)),
                                     as.integer(converter_numero(SEM_NOT))),
    ano_epidemiologico = as.integer(coalesce(epiyear(data_inicio_sintomas),
                                             epiyear(data_notificacao))),
    periodo_se = if_else(!is.na(ano_epidemiologico) & !is.na(semana_epidemiologica),
                         sprintf("%d-SE%02d", ano_epidemiologico, semana_epidemiologica),
                         NA_character_),
    atraso_notificacao = as.numeric(data_notificacao - data_inicio_sintomas),
    atraso_internacao  = as.numeric(data_internacao - data_inicio_sintomas),
    atraso_notificacao = if_else(atraso_notificacao >= 0 & atraso_notificacao <= 60, atraso_notificacao, NA_real_),
    atraso_internacao  = if_else(atraso_internacao  >= 0 & atraso_internacao  <= 60, atraso_internacao,  NA_real_),
    territorio_notificacao = case_when(
      uf_notificacao_ride == "DF" ~ "Distrito Federal",
      uf_notificacao_ride == "GO" ~ "RIDE – Goiás",
      uf_notificacao_ride == "MG" ~ "RIDE – Minas Gerais",
      TRUE ~ "Não classificado"),
    municipio_notificacao = coalesce(municipio_notificacao, str_to_title(ID_MUNICIP), "Município ignorado"),
    territorio_residencia = case_when(
      SG_UF == "DF" ~ "Distrito Federal",
      uf_residencia_ride == "GO" ~ "RIDE – Goiás",
      uf_residencia_ride == "MG" ~ "RIDE – Minas Gerais",
      is.na(CO_MUN_RES) & is.na(SG_UF) ~ "Residência ignorada",
      TRUE ~ "Fora da RIDE"),
    municipio_residencia = case_when(
      SG_UF == "DF" & !is.na(ID_MN_RESI) ~ str_to_title(ID_MN_RESI),
      !is.na(municipio_residencia_ride) ~ municipio_residencia_ride,
      !is.na(ID_MN_RESI) ~ str_to_title(ID_MN_RESI),
      TRUE ~ "Município ignorado"),
    ra_residencia = if_else(SG_UF == "DF",
                            coalesce(normalizar_ra(ID_MN_RESI), normalizar_ra(NM_BAIRRO)),
                            NA_character_),
    unidade_internacao = coalesce(normalizar_texto(str_to_title(NM_UN_INTE)), "Ignorada"),
    tipo_unidade = classificar_unidade(NM_UN_INTE),
    internacao_sem_leito = tipo_unidade == "UPA / Pronto-atendimento",
    sexo = case_when(CS_SEXO %in% c("M","1") ~ "Masculino",
                     CS_SEXO %in% c("F","2") ~ "Feminino", TRUE ~ "Ignorado"),
    raca_cor = case_when(
      converter_numero(CS_RACA) == 1 ~ "Branca",
      converter_numero(CS_RACA) == 2 ~ "Preta",
      converter_numero(CS_RACA) == 3 ~ "Amarela",
      converter_numero(CS_RACA) == 4 ~ "Parda",
      converter_numero(CS_RACA) == 5 ~ "Indígena", TRUE ~ "Ignorada"),
    idade_anos = case_when(
      converter_numero(TP_IDADE) == 1 ~ converter_numero(NU_IDADE_N) / 365.25,
      converter_numero(TP_IDADE) == 2 ~ converter_numero(NU_IDADE_N) / 12,
      converter_numero(TP_IDADE) == 3 ~ converter_numero(NU_IDADE_N), TRUE ~ NA_real_),
    faixa_etaria = case_when(
      is.na(idade_anos) ~ "Ignorada",
      idade_anos < 1  ~ "< 1 ano",   idade_anos < 5  ~ "1–4 anos",
      idade_anos < 10 ~ "5–9 anos",  idade_anos < 20 ~ "10–19 anos",
      idade_anos < 40 ~ "20–39 anos",idade_anos < 60 ~ "40–59 anos",
      idade_anos < 80 ~ "60–79 anos",TRUE ~ "80 anos ou mais"),
    uti = case_when(converter_numero(UTI) == 1 ~ "Sim",
                    converter_numero(UTI) == 2 ~ "Não", TRUE ~ "Ignorado"),
    suporte_ventilatorio = case_when(
      converter_numero(SUPORT_VEN) == 1 ~ "Ventilação invasiva",
      converter_numero(SUPORT_VEN) == 2 ~ "Ventilação não invasiva",
      converter_numero(SUPORT_VEN) == 3 ~ "Não utilizou", TRUE ~ "Ignorado"),
    evolucao = case_when(
      converter_numero(EVOLUCAO) == 1 ~ "Cura",
      converter_numero(EVOLUCAO) == 2 ~ "Óbito",
      converter_numero(EVOLUCAO) == 3 ~ "Óbito por outras causas",
      TRUE ~ "Ignorado/em acompanhamento"),
    caso_encerrado = converter_numero(EVOLUCAO) %in% c(1, 2),
    obito_srag = converter_numero(EVOLUCAO) == 2,
    classificacao_final = case_when(
      converter_numero(CLASSI_FIN) == 1 ~ "SRAG por influenza",
      converter_numero(CLASSI_FIN) == 2 ~ "SRAG por outro vírus respiratório",
      converter_numero(CLASSI_FIN) == 3 ~ "SRAG por outro agente etiológico",
      converter_numero(CLASSI_FIN) == 4 ~ "SRAG não especificada",
      converter_numero(CLASSI_FIN) == 5 ~ "SRAG por COVID-19", TRUE ~ "Não classificada"),
    pcr_realizado  = converter_numero(PCR_RESUL) %in% c(1, 2, 3),
    pcr_detectavel = converter_numero(PCR_RESUL) == 1,
    an_realizado   = converter_numero(RES_AN) %in% c(1, 2, 3),
    an_positivo    = converter_numero(RES_AN) == 1,
    antiviral = case_when(converter_numero(ANTIVIRAL) == 1 ~ "Sim",
                          converter_numero(ANTIVIRAL) == 2 ~ "Não", TRUE ~ "Ignorado"),
    vacina_gripe = case_when(converter_numero(VACINA) == 1 ~ "Sim",
                             converter_numero(VACINA) == 2 ~ "Não", TRUE ~ "Ignorado"),
    possui_cardiopatia = converter_numero(CARDIOPATI) == 1,
    possui_diabetes    = converter_numero(DIABETES) == 1,
    possui_obesidade   = converter_numero(OBESIDADE) == 1,
    possui_imunodepre  = converter_numero(IMUNODEPRE) == 1,
    possui_renal       = converter_numero(RENAL) == 1,
    possui_pneumopatia = converter_numero(PNEUMOPATI) == 1,
    possui_neurologica = converter_numero(NEUROLOGIC) == 1,
    possui_asma        = converter_numero(ASMA) == 1
  )

# --- Detecção viral vetorizada ------------------------------------------------
tp_flu_pcr <- converter_numero(base$TP_FLU_PCR)
tp_flu_an  <- converter_numero(base$TP_FLU_AN)
flu_pcr    <- pos(base$POS_PCRFLU)
flu_an     <- pos(base$POS_AN_FLU)
ind <- cbind(
  "VSR"                     = pos(base$PCR_VSR)   | pos(base$AN_VSR),
  "Parainfluenza 1"         = pos(base$PCR_PARA1) | pos(base$AN_PARA1),
  "Parainfluenza 2"         = pos(base$PCR_PARA2) | pos(base$AN_PARA2),
  "Parainfluenza 3"         = pos(base$PCR_PARA3) | pos(base$AN_PARA3),
  "Parainfluenza 4"         = pos(base$PCR_PARA4),
  "Adenovírus"              = pos(base$PCR_ADENO) | pos(base$AN_ADENO),
  "Metapneumovírus"         = pos(base$PCR_METAP),
  "Bocavírus"               = pos(base$PCR_BOCA),
  "Rinovírus"               = pos(base$PCR_RINO),
  "SARS-CoV-2"              = pos(base$PCR_SARS2) | pos(base$AN_SARS2),
  "Influenza A"             = (flu_pcr & tp_flu_pcr %in% 1) | (flu_an & tp_flu_an %in% 1),
  "Influenza B"             = (flu_pcr & tp_flu_pcr %in% 2) | (flu_an & tp_flu_an %in% 2),
  "Influenza não subtipada" = (flu_pcr & !(tp_flu_pcr %in% c(1,2))) | (flu_an & !(tp_flu_an %in% c(1,2))),
  "Outro vírus respiratório"= pos(base$PCR_OUTRO) | pos(base$AN_OUTRO)
)
ind[is.na(ind)] <- FALSE
rotulos_virus <- colnames(ind)

base$numero_virus <- as.integer(rowSums(ind))
# virus_detectados: string separada por ", " (o app reconstrói a base longa com separate_rows)
base$virus_detectados <- vapply(seq_len(nrow(ind)), function(i) {
  v <- rotulos_virus[ind[i, ]]
  if (length(v) == 0) "Nenhum vírus identificado" else paste(v, collapse = ", ")
}, character(1))
base$codeteccao <- dplyr::case_when(
  base$numero_virus == 0 ~ "Sem vírus identificado",
  base$numero_virus == 1 ~ "Detecção única",
  base$numero_virus >= 2 ~ "Codetecção", TRUE ~ "Ignorado")
base$resultado_viral <- ifelse(base$numero_virus > 0, "Vírus identificado", "Sem vírus identificado")

# População por RA (denominador de incidência por RA)
base <- base %>%
  left_join(ra_df_ref %>% transmute(ra_residencia = regiao_administrativa,
                                    populacao_ra = populacao),
            by = "ra_residencia")

# -----------------------------------------------------------------------------
# 5. SELEÇÃO DAS COLUNAS ANALÍTICAS E GRAVAÇÃO
# -----------------------------------------------------------------------------
pronto <- base %>%
  transmute(
    id_caso,
    data_notificacao, data_inicio_sintomas, data_internacao, data_evolucao,
    ano_epidemiologico, semana_epidemiologica, periodo_se,
    territorio_notificacao, municipio_notificacao,
    territorio_residencia, municipio_residencia,
    ra_residencia, populacao_ra, populacao_residencia,
    unidade_internacao, tipo_unidade, internacao_sem_leito,
    sexo, raca_cor, idade_anos, faixa_etaria,
    virus_detectados, numero_virus, codeteccao, resultado_viral,
    uti, suporte_ventilatorio, evolucao, obito_srag, caso_encerrado,
    classificacao_final,
    pcr_realizado, pcr_detectavel, an_realizado, an_positivo,
    antiviral, vacina_gripe,
    possui_cardiopatia, possui_diabetes, possui_obesidade, possui_imunodepre,
    possui_renal, possui_pneumopatia, possui_neurologica, possui_asma,
    atraso_notificacao, atraso_internacao
  )

cat("  linhas:", nrow(pronto), "| colunas:", ncol(pronto),
    "| com vírus identificado:", sum(pronto$numero_virus > 0), "\n")
pronto
}

# -----------------------------------------------------------------------------
# 6. SÉRIE HISTÓRICA: um parquet pronto por ano
# -----------------------------------------------------------------------------
# Um ano só é refeito quando o recorte dele mudou ou quando este script mudou
# (pronto_ref = data do recorte + assinatura das regras). Assim a execução
# semanal toca só os anos vivos e os arquivos dos anos congelados ficam
# intactos no Git.
manifesto <- ler_manifesto()
manifesto <- manifesto[file.exists(caminho_bruto(manifesto$ano)), , drop = FALSE]
anos <- manifesto$ano
if (length(anos) == 0)
  stop("Nenhum recorte em ", dir_bruto, ". Rode antes: Rscript run_pipeline.R")

# Assinatura das regras: o próprio script, sem depender de fim de linha (CRLF/LF).
regras <- local({
  tmp <- tempfile(); on.exit(unlink(tmp))
  writeLines(sub("\r$", "", readLines("R/03_prepara.R", warn = FALSE, encoding = "UTF-8")),
             tmp, useBytes = TRUE)
  substr(unname(tools::md5sum(tmp)), 1, 12)
})
ref_atual <- paste(manifesto$processado_em, regras, sep = "|")
refazer <- forcar_tudo | is.na(manifesto$pronto_ref) | manifesto$pronto_ref != ref_atual |
           !file.exists(caminho_pronto(anos))
if (!file.exists(arquivo_pronto_atual)) refazer[anos == max(anos)] <- TRUE

dir.create(dir_pronto, showWarnings = FALSE, recursive = TRUE)

for (k in which(refazer)) {
  a <- anos[k]
  pronto <- preparar_base(caminho_bruto(a), id_inicial = a * 1000000L)

  temp <- paste0(caminho_pronto(a), ".tmp")
  duckdb::duckdb_register(con, "pronto_r", pronto)
  dbExecute(con, sprintf("COPY (SELECT * FROM pronto_r ORDER BY id_caso) TO '%s' (%s);",
                         temp, opcoes_parquet))
  duckdb::duckdb_unregister(con, "pronto_r")
  file.rename(temp, caminho_pronto(a))
  cat(sprintf("Gravado: %s (%.2f MB)\n", caminho_pronto(a),
              file.info(caminho_pronto(a))$size / 1024^2))

  # Compatibilidade: o ano mais recente também sai no CSV de sempre,
  # com id_caso começando em 1.
  if (a == max(anos)) {
    atual <- pronto %>% mutate(id_caso = row_number())
    readr::write_excel_csv(atual, arquivo_pronto_atual, na = "")
    cat("Gravado:", arquivo_pronto_atual, "(ano", a, ")\n")
  }

  manifesto$pronto_ref[k] <- ref_atual[k]
  completo <- ler_manifesto()
  completo$pronto_ref[match(a, completo$ano)] <- ref_atual[k]
  gravar_manifesto(completo)
}
if (!any(refazer)) cat("Bases prontas já estão em dia; nada a refazer.\n")

# -----------------------------------------------------------------------------
# 7. SÉRIE SEMANAL AGREGADA (arquivo pequeno, pronto para curvas históricas)
# -----------------------------------------------------------------------------
# Agregada pelo DuckDB direto sobre os parquet de todos os anos. Fica em CSV
# porque é pequena e pode ser lida por painéis HTML sem biblioteca extra.
if (any(refazer) || !file.exists(arquivo_serie)) {
  arquivos_sql <- paste0("['", paste(caminho_pronto(anos), collapse = "','"), "']")
  serie_semanal <- tibble::as_tibble(dbGetQuery(con, sprintf("
    SELECT ano_epidemiologico, semana_epidemiologica, periodo_se,
           territorio_residencia, classificacao_final,
           CAST(count(*) AS INTEGER)                               AS casos,
           CAST(count(*) FILTER (WHERE obito_srag) AS INTEGER)     AS obitos_srag,
           CAST(count(*) FILTER (WHERE uti = 'Sim') AS INTEGER)    AS internacoes_uti,
           CAST(count(*) FILTER (WHERE numero_virus > 0) AS INTEGER) AS virus_identificado
    FROM read_parquet(%s, union_by_name = true)
    WHERE ano_epidemiologico IS NOT NULL AND semana_epidemiologica IS NOT NULL
    GROUP BY ALL
    ORDER BY ano_epidemiologico, semana_epidemiologica,
             territorio_residencia, classificacao_final",
    arquivos_sql)))
  readr::write_excel_csv(serie_semanal, arquivo_serie, na = "")
  cat("Gravado:", arquivo_serie, "| linhas:", nrow(serie_semanal),
      "| casos:", sum(serie_semanal$casos), "\n")
}

dbDisconnect(con, shutdown = TRUE)
cat("Série histórica:", min(anos), "a", max(anos), "|",
    sum(manifesto$linhas_ride), "registros.\n")
