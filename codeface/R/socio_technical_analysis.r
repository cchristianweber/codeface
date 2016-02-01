library(ggplot2)
library(igraph)
library("BiRewire")

source("query.r")
source("config.r")
source("dependency_analysis.r")
source("process_dsm.r")
source("process_jira.r")
source("quality_analysis.r")

plot.to.file <- function(g, outfile) {
  g <- simplify(g,edge.attr.comb="first")
  g <- delete.vertices(g, names(which(degree(g)<2)))
  E(g)[is.na(E(g)$color)]$color <- "#0000001A"
  png(file=outfile, width=10, height=10, units="in", res=300)
  plot(g, layout=layout.kamada.kawai, vertex.size=2,
       vertex.label.dist=0.5, edge.arrow.size=0.5,
       vertex.label=NA)
  dev.off()
}

motif.generator <- function(type, anti=FALSE) {
  motif <- graph.empty(directed=FALSE)
  if (type=="square") {
    motif <- add.vertices(motif, 4)
    motif <- add.edges(motif, c(1,2, 1,3, 2,4, 3,4))
    V(motif)$kind <- c(person.role, person.role, artifact.type, artifact.type)
    V(motif)$color <- vertex.coding[V(motif)$kind]
  }
  else if (type=="triangle") {
    motif <- add.vertices(motif, 3)
    motif <- add.edges(motif, c(1,2, 1,3, 2,3))
    if (anti) motif <- delete.edges(motif, c(1))
    V(motif)$kind <- c(person.role, person.role, artifact.type)
    V(motif)$color <- vertex.coding[V(motif)$kind]
  }
  else {
    motif <- NULL
  }

  return(motif)
}

preprocess.graph <- function(g) {
  ## Remove loops and multiple edges
  g <- simplify(g, remove.multiple=TRUE, remove.loops=TRUE,
                edge.attr.comb="first")

  ## Remove low degree artifacts
  artifact.degree <- degree(g, V(g)[V(g)$kind==artifact.type])
  low.degree.artifact <- artifact.degree[artifact.degree < 2]
  g <- delete.vertices(g, v=names(low.degree.artifact))

  ## Remove isolated developers
  dev.degree <- degree(g, V(g)[V(g)$kind==person.role])
  isolated.dev <- dev.degree[dev.degree==0]
  g <- delete.vertices(g, v=names(isolated.dev))

  return(g)
}

## Configuration
if (!exists("conf")) conf <- connect.db("../../codeface.conf")
dsm.filename <- "/home/mitchell/Downloads/cassandra-2.1.0.dsm.xlsx"
feature.call.filename <- "/home/mitchell/Documents/Feature_data_from_claus/feature-dependencies/cg_nw_f_1_18_0.net"
jira.filename <- "/home/mitchell/Downloads/jira-comment-authors.csv"
defect.filename <- "/home/mitchell/Downloads/cassandra-1.0.7-bugs.csv"
codeface.filename <- "/home/mitchell/Downloads/jiraId_CodefaceId.csv"
con <- conf$con
project.id <- 2
artifact.type <- list("function", "file", "feature")[[2]]
dependency.type <- list("co-change", "dsm", "feature_call", "none")[[4]]
quality.type <- list("corrective", "defect")[[2]]
communication.type <- list("mail", "jira")[[1]]
person.role <- "developer"
start.date <- "2015-07-01"
end.date <- "2015-10-01"
file.limit <- 30
historical.limit <- ddays(365)

## Compute dev-artifact relations
vcs.dat <- query.dependency(con, project.id, artifact.type, file.limit,
                            start.date, end.date, impl=FALSE, rmv.dups=FALSE)
vcs.dat$author <- as.character(vcs.dat$author)

## Compute communication relations
if (communication.type=="mail") {
  comm.dat <- query.mail.edgelist(con, project.id, start.date, end.date)
  colnames(comm.dat) <- c("V1", "V2", "weight")
} else if (communication.type=="jira") {
  comm.dat <- load.jira.edgelist(jira.filename, codeface.filename)
}
comm.dat[, c(1,2)] <- sapply(comm.dat[, c(1,2)], as.character)

## Compute entity-entity relations
relavent.entity.list <- unique(vcs.dat$entity)
if (dependency.type == "co-change") {
  start.date.hist <- as.Date(start.date) - historical.limit
  end.date.hist <- start.date

  commit.df.hist <- query.dependency(con, project.id, artifact.type, file.limit,
                                     start.date.hist, end.date.hist)

  commit.df.hist <- commit.df.hist[commit.df.hist$entity %in% relavent.entity.list, ]

  ## Compute co-change relationship
  freq.item.sets <- compute.frequent.items(commit.df.hist)
  ## Compute an edgelist
  dependency.dat <- compute.item.sets.edgelist(freq.item.sets)
  names(dependency.dat) <- c("V1", "V2")

} else if (dependency.type == "dsm") {
  dependency.dat <- load.dsm.edgelist(dsm.filename)
  dependency.dat <-
    dependency.dat[dependency.dat[, 1] %in% relavent.entity.list &
                   dependency.dat[, 2] %in% relavent.entity.list, ]
} else if (dependency.type == "feature_call") {
  graph.dat <- read.graph(feature.call.filename, format="pajek")
  V(graph.dat)$name <- V(graph.dat)$id
  dependency.dat <- get.data.frame(graph.dat)
  dependency.dat <-
      dependency.dat[dependency.dat[, 1] %in% relavent.entity.list &
                     dependency.dat[, 2] %in% relavent.entity.list, ]
  names(dependency.dat) <- c("V1", "V2")
} else {
  dependency.dat <- data.frame()
}

## Compute node sets
node.function <- unique(vcs.dat$entity)
node.dev <- unique(c(vcs.dat$author))

## Generate bipartite network
g.nodes <- graph.empty(directed=FALSE)
g.nodes <- add.vertices(g.nodes, nv=length(node.dev),
                        attr=list(name=node.dev, kind=person.role,
                                  type=TRUE))
g.nodes  <- add.vertices(g.nodes, nv=length(node.function),
                         attr=list(name=node.function, kind=artifact.type,
                                   type=FALSE))

## Add developer-entity edges
vcs.edgelist <- with(vcs.dat, ggplot2:::interleave(author, entity))
g.bipartite <- add.edges(g.nodes, vcs.edgelist, attr=list(color="#00FF001A"))

## Add developer-developer communication edges
g <- graph.empty(directed=FALSE)
## Remove persons that don't appear in VCS data
comm.inter.dat <- comm.dat[comm.dat$V1 %in% node.dev & comm.dat$V2 %in% node.dev, ]
comm.edgelist <- as.character(with(comm.inter.dat, ggplot2:::interleave(V1, V2)))
g <- add.edges(g.bipartite, comm.edgelist, attr=list(color="#FF00001A"))

## Add entity-entity edges
if(nrow(dependency.dat) > 0) {
  dependency.edgelist <- as.character(with(dependency.dat,
                                           ggplot2:::interleave(V1, V2)))
  g <- add.edges(g, dependency.edgelist)
}

## Apply filters
g <- preprocess.graph(g)

## Apply vertex coding
vertex.coding <- c()
vertex.coding[person.role] <- 1
vertex.coding[artifact.type] <- 2
V(g)$color <- vertex.coding[V(g)$kind]

## Define motif
motif <- motif.generator("triangle")
motif.anti <- motif.generator("triangle", anti=TRUE)

## Count subgraph isomorphisms
motif.count <- count_subgraph_isomorphisms(motif, g, method="vf2")

## Extract subgraph isomorphisms
motif.subgraphs <- subgraph_isomorphisms(motif, g, method="vf2")
motif.subgraphs.anti <- subgraph_isomorphisms(motif.anti, g, method="vf2")

## Compute null model
niter <- 1000
motif.count.null <- c()

motif.count.null <-
  sapply(seq(niter),
    function(i) {
      ## Rewire dev-artifact bipartite
      g.bipartite.rewired <- g.bipartite #birewire.rewire.bipartite(simplify(g.bipartite), verbose=FALSE)

      ## Add rewired edges
      g.null <- add.edges(g.nodes,
                          as.character(with(get.data.frame(g.bipartite.rewired),
                                            ggplot2:::interleave(from, to))))

      ## Aritfact-artifact edges
      if (nrow(dependency.dat) > 0) {
        g.null <- add.edges(g.null, dependency.edgelist)
      }

      ## Test degree dist
      #if(!all(sort(as.vector(degree(g.null))) ==
      #        sort(as.vector(degree(g.bipartite))))) stop("Degree distribution not conserved")

      ## Rewire dev-dev communication graph
      g.comm <- graph.data.frame(comm.inter.dat)
      g.comm.null <- birewire.rewire.undirected(simplify(g.comm),
                                                verbose=FALSE)

      ## Test degree dist
      if(!all(sort(as.vector(degree(g.comm.null))) ==
              sort(as.vector(degree(g.comm))))) stop("Degree distribution not conserved")

      g.null <- add.edges(g.null,
                          as.character(with(get.data.frame(g.comm.null),
                                       ggplot2:::interleave(from, to))))

      ## Code and count motif
      V(g.null)$color <- vertex.coding[V(g.null)$kind]

      g.null <- preprocess.graph(g.null)

      res <- count_subgraph_isomorphisms(motif, g.null, method="vf2")

      return(res)})

motif.count.dat <- data.frame(motif.count.null=motif.count.null,
                              motif.count.empirical=motif.count)


p.null <- ggplot(data=motif.count.dat, aes(x=motif.count.null)) +
       geom_histogram(aes(y=..density..), colour="black", fill="white") +
       geom_point(aes(x=motif.count.empirical), y=0, color="red", size=5) +
       geom_density(alpha=.2, fill="#AAD4FF")
ggsave(file="motif_count.png", p.null)

p.comm <- ggplot(data=data.frame(degree=degree(graph.data.frame(comm.dat))), aes(x=degree)) +
    geom_histogram(aes(y=..density..), colour="black", fill="white") +
    geom_density(alpha=.2, fill="#AAD4FF")
ggsave(file="communication_degree_dist.png", p.comm)

plot.to.file(g, "socio_technical_network.png")

## Perform quality analysis
if (quality.type=="defect") {
  quality.dat <- load.defect.data(defect.filename)
} else {
  quality.dat <- get.corrective.count(con, project.id, start.date, end.date,
                                      artifact.type)
}

artifacts <- count(data.frame(entity=unlist(lapply(motif.subgraphs,
                                                   function(i) i[[3]]$name))))
anti.artifacts <- count(data.frame(entity=unlist(lapply(motif.subgraphs.anti,
                                                        function(i) i[[3]]$name))))
compare.motifs <- merge(artifacts, anti.artifacts, by='entity', all=TRUE)
compare.motifs[is.na(compare.motifs)] <- 0
names(compare.motifs) <- c("entity", "motif.count", "motif.anti.count")

artifacts.dat <- merge(quality.dat, compare.motifs, by="entity")