options(digits.secs = 6)
if (Sys.info()['sysname'] != "Windows") {
    options(encoding = 'UTF-8')
    Sys.setlocale("LC_ALL", "en_US.utf8")
} else {
    Sys.setlocale("LC_ALL", "English")
}
require(concerto5)
require(parallel)

dbDriver = commandArgs(TRUE)[4]
switch(dbDriver,
    pdo_mysql = require("RMySQL"),
    pdo_sqlsrv = require("RSQLServer")
)
rm(dbDriver)

fromJSON = function(txt, simplifyVector = FALSE, simplifyDataFrame = simplifyVector,
simplifyMatrix = simplifyVector, flatten = FALSE, ...){
    result = jsonlite::fromJSON(txt, simplifyVector, simplifyDataFrame, simplifyMatrix, flatten, ...)
    return(result)
}

toJSON = function(x, dataframe = c("rows", "columns", "values"), matrix = c("rowmajor",
"columnmajor"), Date = c("ISO8601", "epoch"), POSIXt = c("string",
"ISO8601", "epoch", "mongo"), factor = c("string", "integer"),
complex = c("string", "list"), raw = c("base64", "hex", "mongo"),
null = c("list", "null"), na = c("null", "string"), auto_unbox = TRUE,
digits = 4, pretty = FALSE, force = FALSE, ...) {
    result = jsonlite::toJSON(x, dataframe, matrix, Date, POSIXt, factor, complex, raw, null, na, auto_unbox, digits, pretty, force, ...)
    result = as.character(result)
    return(result)
}

SOURCE_CLIENT = 0
SOURCE_PROCESS = 1
SOURCE_SERVER = 2

RESPONSE_VIEW_TEMPLATE = 0
RESPONSE_FINISHED = 1
RESPONSE_SUBMIT = 2
RESPONSE_STOP = 3
RESPONSE_STOPPED = 4
RESPONSE_VIEW_FINAL_TEMPLATE = 5
RESPONSE_UNRESUMABLE = 11
RESPONSE_WORKER = 15
RESPONSE_ERROR = - 1

STATUS_RUNNING = 0
STATUS_STOPPED = 1
STATUS_FINALIZED = 2
STATUS_ERROR = 3

concerto <- list()
concerto$cache <- list(tests = list(), templates = list(), tables = list())
concerto$promoted <- list()
concerto$templateParams <- list()

#DEFAULTS START
concerto$promoted$template_def <- "{\"layout\":\"default_layout\",\"header\":\"Your header goes here. For example, it could be a logo.\",\"footer\":\"Your footer goes here. For example, it could be a copyright sign. You might also have links to a privacy policy.\"}"
#DEFAULTS END

fifo_path = commandArgs(TRUE)[1]
public_dir = commandArgs(TRUE)[2]
media_url = commandArgs(TRUE)[3]

concerto.log("starting listener")
queue = c()
unlink(paste0(fifo_path,"/*"))
while (T) {
    fpath = ""
    if(length(queue) == 0) {
        queue = list.files(fifo_path, full.names=TRUE)
    }
    if(length(queue) > 0) {
        fpath = queue[1]
        queue = queue[-1]
    } else {
        Sys.sleep(0.25)
        next
    }
    con = fifo(fpath, blocking=TRUE, open="rt")
    concerto.log("incoming session request")
    response = readLines(con, warn = FALSE, n = 1, ok = FALSE)
    response = tryCatch({
        fromJSON(response)
    }, error = function(e) {
        message(e)
        message(response)
        q("no", 1)
    })
    close(con)
    unlink(fpath)
    message(response$sessionId)
    mcparallel({
        sink(file = response$rLogPath, append = TRUE, type = "output", split = FALSE)
        concerto.log("starting session")
        rm(fifo_path)
        rm(queue)
        rm(fpath)
        rm(con)
        concerto$workingDir <- response$workingDir
        concerto$publicDir <- public_dir
        rm(public_dir)
        concerto$mediaUrl <- media_url
        rm(media_url)
        concerto$maxExecTime <- as.numeric(response$maxExecTime)
        concerto$testNode <- response$testNode
        concerto$client <- response$client
        submitter <- response$submitter
        concerto$connectionParams <- response$connection

        concerto$sessionFile <- paste0(concerto$workingDir, "session.Rs")
        concerto$submitter.host <- submitter$host
        concerto$submitter.port <- submitter$port
        rm(submitter)

        concerto$connection <- concerto5:::concerto.db.connect(concerto$connectionParams$driver, concerto$connectionParams$username, concerto$connectionParams$password, concerto$connectionParams$dbname, concerto$connectionParams$host, concerto$connectionParams$unix_socket, concerto$connectionParams$port)

        concerto$session <- as.list(concerto5:::concerto.session.get(response$sessionId))
        concerto$session$previousStatus <- concerto$session$status
        concerto$session$status <- STATUS_RUNNING
        concerto$session$params <- fromJSON(concerto$session$params)

        concerto$flow <- list()
        concerto$cache <- list(tables = list(), templates = list(), tests = list())

        returns <<- list()
        tryCatch({
            setwd(concerto$workingDir)
            setTimeLimit(elapsed = concerto$maxExecTime, transient = TRUE)
            returns <<- concerto.test.run(concerto$session["test_id"], concerto$session$params, TRUE)

            if (concerto$session$status == STATUS_FINALIZED) {
                concerto5:::concerto.session.finalize(RESPONSE_VIEW_FINAL_TEMPLATE, returns)
            } else if (concerto$session$status == STATUS_RUNNING) {
                concerto5:::concerto.session.finalize(RESPONSE_FINISHED, returns)
            }
        }, error = function(e) {
            if (concerto$session$status == STATUS_RUNNING) {
                concerto.log(e)
                response = RESPONSE_ERROR
                if (e$message == "session unresumable") {
                    response = RESPONSE_UNRESUMABLE
                }
                concerto$session$error <<- e
                concerto$session$status <<- STATUS_ERROR
                concerto5:::concerto.session.update()
                concerto5:::concerto.server.respond(response)
                q("no",1)
            }
        })

        q("no")
    }, detached = TRUE)
}
concerto.log("listener closing")