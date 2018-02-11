# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

"""PlatformIO Rules.

These are Bazel Skylark rules for building and uploading
[Arduino](https://www.arduino.cc/) programs using the
[PlatformIO](http://platformio.org/) build system.
"""


# A relative filename of a file.
_FILENAME = "{dirname}/{filename}"


# Path for the libraries in lib
_PATH_LIBRARY = "lib/{path}"

# Command that copies the source to the destination. It creates the requiered 
# path for the destination.
# -r "recursively" copies all the content of the source if it is a directory
# -v verbose printing
# TODO: See if the -u option to specify update the newer files is needed
_COPY_COMMAND="/bin/cp -r -v {source} {destination}"


# Command that executes the PlatformIO build system and builds the project in
# the specified directory.
_BUILD_COMMAND="platformio.exe run -d {project_dir}"


# Creates the specify directory creating all the parents directories
# needed. If some or all the path already exists doesnt get an error
# -v verbose output
# -p create the needed directories for the path
_CREATE_DIR="/bin/mkdir -v -p {dir}"


# Command that erase all the content of a directory
# -r "recursively" remove all the content
# f dont ask any confirmation
# -v verbose
_DELETE_DIR_CONTENT_COMMAND="/bin/rm -rf -v {dir}/*"


# Command that appends to a file the #include "Arduino.h"
# -i modify the same file and save it there
_APPEND_INCLUDE_ARDUINO="/bin/sed -i '1s/^/#include \"Arduino.h\"\\n/' {filename}"


# Header used in the shell script that makes platformio_project executable.
# Execution will upload the firmware to the Arduino device.
_SHELL_HEADER="#!/bin/bash"


def _convert_dotted_path_to_slashed(strPath):
  """
  Method that convert the dotted path to a slashed path.
  Example: dir1.dir2.dir3 -> dir1/dir2/dir3

  Args:
    strPath: A string. The path with dots

  Outputs:
    The path with the dots replaced with /
  """
  return strPath.replace(".", "/")

def _validate_path(strPath):
  """
  Method that validates to be a valid path of a directory. It can be a full path.
  This will call fail if the path is not ok.

  NOTE: This doesnt fully validate the path. Because bazel validate it because it
  is used for the path of the output.

  Args:
    strPath: A string. The path with dots

  """
  if strPath.find("/") != -1:
    fail("Attribute path cannot have a /")
  elif strPath.startswith(".") or strPath.endswith("."):
    fail("Attribute path cannot start or end with .")
  elif strPath.strip() != strPath:
    fail("Attribute path cannot have a blank space")
  elif strPath.find("..") != -1:
    fail("Attribute path cannot have more than one . together")


def _platformio_library_impl(ctx):
  """
  Collects all transitive dependancies and emits the directory
  with all the files of this library.

  Args:
    ctx: The Skylark context.

  Outputs:
    transitive_lib_directory: A directory containing the files of
      this library inside of the correct directories for the specified path.
  """
  dottedPath = ctx.attr.path
  _validate_path(dottedPath)
  slashedPath = _convert_dotted_path_to_slashed(dottedPath)
  completePath = "{0}/{1}".format(ctx.outputs.lib_directory.basename, slashedPath)

  # Create the directory that will hold all the files.
  completePathDir = ctx.actions.declare_directory(completePath)
  commands = [_CREATE_DIR.format(dir=completePathDir.path)]
  outputs= [ctx.outputs.lib_directory, completePathDir]

  # Empty the directory to ensure that it doesnt have before-declared files
  # TODO: Check what order is better: first make dir and then empty it or 
  #   the other way. And see if is better to create the dir in a separate
  #   command and then use it as input and executes the empty command.
  commands.append(_DELETE_DIR_CONTENT_COMMAND.format(dir=completePathDir.path))

  # Copy all header and source files.
  inputs = []
  for files in [ctx.attr.hdrs, ctx.attr.srcs]:
    for target in files:
      for f in target.files:
        # The name of the file is the relative path to the file, this enables us
        # to prepend the name to the path.
        file_name = f.basename #The file's name
        file_source = f
        file_destination = ctx.new_file(
          _FILENAME.format(dirname=completePath, filename=file_name))
        inputs.append(file_source)
        outputs.append(file_destination)
        # TODO: See if is better to copy in one time all the files to the directory
        commands.append(_COPY_COMMAND.format(
            source=file_source.path,
            destination=file_destination.path))

  # TODO: Update this to use the run_shell method
  ctx.action(
      inputs=inputs,
      outputs=outputs,
      command="\n".join(commands),
  )

  # Collect the directory files produced by all transitive dependancies.
  transitive_lib_directory = set([ctx.outputs.lib_directory])
  for dep in ctx.attr.deps:
    transitive_lib_directory += dep.transitive_lib_directory
  return struct(
    transitive_lib_directory = transitive_lib_directory,
  )


def _emit_ini_file_action(ctx):
  """Emits a Bazel action that generates the PlatformIO configuration file.

  Args:
    ctx: The Skylark context.
  """
  environment_kwargs = []
  if ctx.attr.environment_kwargs:
    environment_kwargs.append("")

  for key, value in ctx.attr.environment_kwargs.items():
    if key == "" or value == "":
      continue
    environment_kwargs.append("{key} = {value}".format(key=key, value=value))
  ctx.template_action(
      template=ctx.file._platformio_ini_tmpl,
      output=ctx.outputs.platformio_ini,
      substitutions={
          "%board%": ctx.attr.board,
          "%platform%": ctx.attr.platform,
          "%framework%": ctx.attr.framework,
          "%environment_kwargs%": "\n".join(environment_kwargs),
      },
  )


def _emit_main_file_action(ctx):
  """Emits a Bazel action that outputs the project main C++ file.

  Args:
    ctx: The Skylark context.
  """
  # TODO: Create first the directory src
  commands = [_COPY_COMMAND.format(
    source=ctx.file.src.path, destination=ctx.outputs.main_cpp.path)]

  # We append at the begining the #include "Arduino.h" with the idea 
  # that if it is already there, the .h has the #ifndef protection
  # TODO: Maybe we can have a smarter script of 'sed' where we check
  #   if it already has the #include, to avoid arduino.h that doesnt 
  #   have the ifndef. Or/and have a attr that says if it needs the
  #   #include. Because also I think not all the platforms uses 
  #   the Arduino.h
  commands.append(_APPEND_INCLUDE_ARDUINO.format(
    filename=ctx.outputs.main_cpp.path))


  ctx.action(
      inputs=[ctx.file.src],
      outputs=[ctx.outputs.main_cpp],
      command="\n".join(commands),
  )


def _emit_build_action(ctx, project_dir):
  """
  Emits a Bazel action that puts the libraries in a "lib" directory
  and builds the project.

  Args:
    ctx: The Skylark context.
    project_dir: A string, the main directory of the PlatformIO project.
  """
  transitive_lib_directory = set()
  for dep in ctx.attr.deps:
    transitive_lib_directory += dep.transitive_lib_directory

  # Create the directory "lib" that will hold all the libraries.
  libs_dir = ctx.actions.declare_directory("lib")
  commands = [_CREATE_DIR.format(dir=libs_dir.path)]
  outputs= [libs_dir]

  # Erase the "lib" directory to ensure that it doesnt have before-declared libraries
  commands.append(_DELETE_DIR_CONTENT_COMMAND.format(dir=libs_dir.path))

  # Create the declared path and copy there the libraries' files into lib/
  for lib_dir in transitive_lib_directory:
    # Declare the directory inside lib/ that will be the dotted-parent-dir of the 
    # library with the resulting following format:
    # lib/path.in.attr/path/in/attr
    dirLibrary = ctx.actions.declare_directory(
      _PATH_LIBRARY.format(path=lib_dir.basename))
    outputs.append(dirLibrary)

    # Copy the dotted-parent-dir of the library with all the dirs for the path 
    # and the files into the directory just created inside lib/
    commands.append(_COPY_COMMAND.format(
        source=lib_dir.path, destination=libs_dir.path))

  commands.append(_BUILD_COMMAND.format(project_dir=project_dir))

  # The PlatformIO build system needs the project configuration file, the main
  # file and all the transitive dependancies.
  inputs=[ctx.outputs.platformio_ini, ctx.outputs.main_cpp]
  # TODO: Join this part with the one above
  for lib_dir in transitive_lib_directory:
    inputs.append(lib_dir)

  outputs.append(ctx.outputs.firmware_elf)
  outputs.append(ctx.outputs.firmware_hex)
  ctx.action(
      inputs=inputs,
      outputs=outputs,
      command="\n".join(commands),
      env={
        # The PlatformIO binary assumes that the build tools are in the path.
        "PATH":"/bin",
      },
      execution_requirements={
        # PlatformIO cannot be executed in a sandbox.
        "local": "1",
      },
  )


def _platformio_project_impl(ctx):
  """Builds and optionally uploads (when executed) a PlatformIO project.

  Args:
    ctx: The Skylark context.

  Outputs:
    main_cpp: The C++ source file containing the Arduino setup() and loop()
      functions renamed according to PlatformIO needs.
    platformio_ini: The project configuration file for PlatformIO.
    firmware_elf: The compiled version of the Arduino firmware for the specified
      board.
    firmware_hex: The firmware in the hexadecimal format ready for uploading.
  """
  _emit_ini_file_action(ctx)
  _emit_main_file_action(ctx)

  # Determine the build directory used by Bazel, that is the directory where
  # our output files will be placed.
  project_dir = ctx.outputs.platformio_ini.dirname
  _emit_build_action(ctx, project_dir)


platformio_library = rule(
  implementation=_platformio_library_impl,
  outputs = {
      # TODO: Maybe is better to put as output each file instead of whole directory
      "lib_directory": "%{path}-%{name}",
  },
  attrs={
    "path": attr.string(mandatory=True),
    "hdrs": attr.label_list(
        allow_files=[".h"],
        # TODO: Maybe is better to make at least this mandatory and not allow empty.
        allow_empty=True,
    ),
    "srcs": attr.label_list(
        allow_files=[".c", ".cc", ".cpp", ".ino", ".pde"],
        allow_empty=True,
    ),
    "deps": attr.label_list(
        providers=["transitive_lib_directory"],
    ),
  },
)
"""
Defines a C++ library that can be imported in an PlatformIO project.

The PlatformIO build system requires a set project directory structure. All
libraries must be under the lib directory.

If you have a C++ library with files my_lib.h and my_lib.cc, using this rule:
```
platformio_library(
    # Start with an uppercase letter to keep the Arduino naming style.
    name = "My_lib",
    path = "lib1.src.a1",
    hdr = "my_lib.h",
    src = "my_lib.cc",
)
```

Will generate a directory containing the following structure:
```
lib1.src.a1
  lib1/src/a1
    My_lib.h
    My_lib.cpp
```

In the Arduino code, you should include this as follows. The PLATFORMIO_BUILD
will be set when the library is built by the PlatformIO build system.
```
#ifdef PLATFORMIO_BUILD
#include "lib1/src/a1/My_lib.h"  // This is how PlatformIO sees and includes the library.
#else
#include "actual/path/to/my_lib.h" // This is for native C++.
#endif
```

Args:
  name: A string, the unique name for this rule. Start with an uppercase letter
    and use underscores between words.
  path: A string. The path that will be used to 'include' the library files in
    the c++ code. Should be a valid path componed by one or several directories
    like: grand/father/son
  hdrs: A list of labels of header files (.h) of the library.
  srcs: A list of labels of source files (.c,.cc,.cpp,.ino,.pde) of the library.
  deps: A list of Bazel targets, other platformio_library targets that this one
    depends on.

Outputs:
  transitive_lib_directory: A directory containing the files of
    this library.
"""

platformio_project = rule(
    implementation=_platformio_project_impl,
    outputs = {
      "main_cpp": "src/main.cpp",
      "platformio_ini": "platformio.ini",
      "firmware_elf": ".pioenvs/%{board}/firmware.elf",
      "firmware_hex": ".pioenvs/%{board}/firmware.hex",
    },
    attrs={
      "_platformio_ini_tmpl": attr.label(
        default=Label("//platformio:platformio_ini_tmpl"),
        allow_single_file=True,
      ),
      "src": attr.label(
        allow_single_file=[".ino",".cpp",".cc",".c",".pde",".h"], #Allow .h also because platformio_library doesnt compile
        mandatory=True,
      ),
      "board": attr.string(mandatory=True),
      "platform": attr.string(default="atmelavr"),
      "framework": attr.string(default="arduino"),
      "environment_kwargs": attr.string_dict(allow_empty=True),
      "deps": attr.label_list(
        providers=["transitive_lib_directory"],
      ),
    },
)
"""Defines a project that will be built and uploaded using PlatformIO.

Creates, configures and runs a PlatformIO project. This is equivalent to running:
```
platformio run
```

This rule is executable and when executed, it will upload the compiled firmware
to the connected Arduino device. This is equivalent to running:
platformio run -t upload

Args:
  name: A string, the unique name for this rule.
  src: A string, the name of the C++ source file, the main file for the project
    that contains the Arduino setup() and loop() functions. This is mandatory.
    This file may or not have the #include "Arduino.h", this will be automatically
    added in either case. This because the Arduino IDE's preprocessor appends
    this automatically when building.
  board: A string, name of the Arduino board to build this project for. You can
    find the supported boards in the
    [PlatformIO Embedded Boards Explorer](http://platformio.org/boards). This is
    mandatory.
  platform: A string, the name of the
    [development platform](
    http://docs.platformio.org/en/latest/platforms/index.html#platforms) for
    this project.
  framework: A string, the name of the
    [framework](
    http://docs.platformio.org/en/latest/frameworks/index.html#frameworks) for
    this project.
  environment_kwargs: A dictionary of strings to strings, any provided keys and
    values will directly appear in the generated platformio.ini file under the
    env:board section. Refer to the [Project Configuration File manual](
    http://docs.platformio.org/en/latest/projectconf.html) for the available
    options.
  deps: A list of Bazel targets, the platformio_library targets that this one
    depends on.

Outputs:
  main_cpp: The C++ source file containing the Arduino setup() and loop()
  functions renamed according to PlatformIO needs.
  platformio_ini: The project configuration file for PlatformIO.
  firmware_elf: The compiled version of the Arduino firmware for the specified
    board.
  firmware_hex: The firmware in the hexadecimal format ready for upload.
"""
