#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convenience launcher — equivalent to `python -m bjorn_manager`."""
import runpy
runpy.run_module("bjorn_manager", run_name="__main__", alter_sys=True)
