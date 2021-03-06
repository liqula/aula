FIXME: we do not depend on the thentos git repo any more, but on some thentos packages from hackage.  this document does not reflect this change yet.


# new process

This section describes a simpler process for keeping updates in
`github.com/liqd/aula{,-docker}` in sync.  The following sections may
be outdated.

quay.io builts images from branches and tags them with the branch
name, so we can pin the image to that branch in aula.  The tricky part
is to merge and refresh everything in the right order.  (For instance,
we shouldn't leave the aula submodule in aula-docker pinned to the
branch, but move it back to master.)

The new branch in aula is called `<aula-branch>` in the following; the
new aula-docker branch is called `<aula-docker-branch>` and should
have the form `aula-docker-0.<i>`, where `<i>` is a fresh integer.

This is the story of updating aula and aula-docker in sync:

In aula:

- `git checkout -b <aula-branch>`
- `find docker/ .travis* Makefile -type f -exec perl -i -pe 's!quay.io/liqd/aula\S+!quay.io/liqd/aula:<aula-branch>!' {} \;`
- make your changes, commit.

in aula-docker:

- make sure that all previous aula-docker releases have been merged.
- `git checkout master; git checkout -b <aula-docker-branch>`
- `cd aula; git fetch; git checkout <aula-branch>; cd ..; git add aula; git commit -m 'bump aula; move to branch'`
- make your changes, commit, push.
- review
- wait for quay.io to build image successfully and tag it with `<aula-branch>`.
- clear for merge.  (but do not merge yet!)

in aula:

- push your changes.
- review, merge.

in aula-docker:

- `cd aula; git fetch; git checkout master; cd ..; git add aula; git commit -m 'dump aula; move back to master'`
- merge.


# thoughts on how to use docker

On the one hand, docker makes it easy to handle system state; on the
other, it creates a lot of traffic volumes, and debugging cycles of
half an hour or more can lead to long outages if something vital
breaks.

This document collects the lessons learned with using docker, and is
our shot at docker best practices.


## Post-mortem

This is the description and analysis of a problem that cost us more
than 1 day to fix, so we decided it may be interesting to others.

We are running two repositories that are developed in parallel and are
provided by the same docker image: thentos and aula.  When we upgraded
both repos with downwards-incompatible changes, we ended up with a
diamond dependency:

- bumped thentos-core to 0.3
- docker image update to thentos-core-0.3
- new docker image breaks aula master build, which still depends on thentos-core-0.2
- aula feature branch merged to master, now aula depends on thentos-0.3
- vector library double dependency, breaking the travis build

At this point, we made the mistake of not adding a `==` constraint the
resp. cabal files, but switching the docker image from cabal to stack.


## Lessons lerned

1. Never try to solve more than one problem at once!  If something is
   broken, try the easiest thing that makes things work again!
2. Use https://quay.io/.  They have build machines, and those are
   faster than travis.  Anyway travis is intended for integration
   testing, not for docker image compilation.
3. Build locally (`docker build` rather than `git push`).  This can be
   faster, but more importantly it contains any breakage to your
   machine and doesn't affect others in the team.


## Processes

### The idea

- freeze version of thentos-core dependency in aula repo.
- have release versions for every docker image update.
- if something goes wrong, revert thentos and aula to last working
  release, pull the matching docker image, and resume from there.


### upgrade

You've just made changes to both thentos and aula, and neither of the
new versions works with the old version of the other.  So you need to
upgrade both concurrently in docker.

1. push thentos feature branch, wait for travis, merge, ./misc/bump-version.sh
1. move submodules in aula-docker to new thentos master, aula feature branch
1. build docker image locally
1. test aula on local docker image
1. push docker image to quay.io
1. push aula feature branch, wait for travis, merge, ./make-version.sh
1. move submodule in aula-docker to new aula master
1. push aula-docker
1. wait for the quay.io/liqd/aula build
1. run the tag-latest-build.sh on your local, which checks out the latest build, tags it with
   the git hash and pushes the tag to quay.io

FIXME: we should probably provide some of the shell commands to do all
that?


### revert (travis)

If there is an issue with the latest combination of thentos, aula,
aula-docker, travis could fail to build aula.

- visit https://quay.io/repository/liqd/aula?tab=builds.
- select the commit hash of a build that is known to work.
- in the aula repo on the feature branch that has the issue, change `.travis.yml` as follows:

```
env:
    - AULA_IMAGE=quay.io/liqd/aula:<working-commit-hash> AULA_SOURCE=/liqd/aula
```

it may also help to rebase the feature branch (still in the aula repo)
into the past, onto a working release tag, or temporarily revert some
of the changes you work on.


### revert (developer)

You have found out that there is an issue with the latest combination
of thentos, aula, aula-docker, and you need to get an older, working
combination back.

- visit https://quay.io/repository/liqd/aula?tab=builds
- select the commit hash of a build that is known to work, say COMMIT_HASH
- `git clone https://github.com/liqd/aula-docker -b $COMMIT_HASH`
- `cd aula && git status && cd ../thentos && git status`
- let's call the commit hashes you have found THENTOS_HASH and AULA_HASH

Now you can set everything up the way it worked on quay.io.

FIXME: not tested.

```shell
docker pull quay.io/liqd/aula:$COMMIT_HASH
cd .../thentos && git fetch && git checkout $THENTOS_HASH
cd .../aula && git fetch && git checkout $AULA_HASH
```


## Other ideas (probably not relevant for us, but fun)

If you are not fond of excessive git submodules or if it
doesn't apply because you get other git repos from elsewhere, you can
configure the required versions in resp. one-line config files and
modify the `Dockerfile` to move those repos to those versions:

```shell
RUN cd .../thentos && \
    git checkout `cat .../aula-docker/thentos-release-tag.txt` && \
    ...
```
